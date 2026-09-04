defmodule MessageService.StatusesTest do
  @moduledoc """
  Status commit 1 on real SQL (`@tag :postgres_integration`). Proves: THE PREDATING AUDIENCE RULE (a
  conversation started AFTER the post admits nobody; a late group joiner sees nothing; the OWNER joining
  a group after posting doesn't retroactively admit that group; predating contacts see everything);
  blocks deny live in both directions; leaving denies live; expiry is filter-at-read (feed, list, and
  media_allowed all go dark at expires_at); the owner's own list bypasses the audience; owner-delete
  tombstones + purges immediately; and THE SWEEP (run inline — the async task can't share the SQL
  sandbox) purges expired media, stamps media_purged_at, and hard-deletes >30-day rows.

  COMMIT 2 adds: audience MODES enforced inside the same predicate ('except' excludes, 'only' restricts)
  and COMPOSING with the predating rule (an 'only' listee who joined the shared conversation AFTER the
  post is still denied — modes narrow, never widen); view recording gated by that predicate (so a BLOCKED
  viewer provably never gets a row); and the owner's viewer list under read-receipt reciprocity — a
  receipts-off viewer is ABSENT from the list while their view ROW still exists, and a receipts-off OWNER
  sees an empty list with viewers_hidden.

  COMMIT 3 adds status_for_reply/1 — the audience predicate's FOURTH consumer, evaluated at REPLY time:
  the TEXT-ONLY snapshot (kind + capped excerpt, no media pointer), :status_not_visible when the caller
  fell out of the audience since opening it (distinct from :status_not_found for unknown/expired), and
  the snapshot's independence from the post's later fate.
  """
  use MessageService.DataCase, async: false

  alias MessageService.Statuses

  defmodule PurgeStub do
    def start_link, do: Agent.start_link(fn -> [] end, name: __MODULE__)
    def purged, do: Agent.get(__MODULE__, &Enum.reverse/1)

    def purge_asset(%{"media_id" => media_id}) do
      Agent.update(__MODULE__, &[media_id | &1])
      {:ok, %{purged: true}}
    end
  end

  setup do
    start_supervised!(%{id: PurgeStub, start: {PurgeStub, :start_link, []}})

    prev = %{
      persistence: Application.get_env(:message_service, :message_persistence, false),
      sweep: Application.get_env(:message_service, :status_sweep_async),
      media: Application.get_env(:shared_infra, :media_client_adapter)
    }

    Application.put_env(:message_service, :message_persistence, true)
    # The write-amortised sweep spawns a Task in prod; inline-only here (sandbox connection).
    Application.put_env(:message_service, :status_sweep_async, false)
    Application.put_env(:shared_infra, :media_client_adapter, PurgeStub)

    on_exit(fn ->
      Application.put_env(:message_service, :message_persistence, prev.persistence)

      if prev.sweep == nil,
        do: Application.delete_env(:message_service, :status_sweep_async),
        else: Application.put_env(:message_service, :status_sweep_async, prev.sweep)

      if prev.media == nil,
        do: Application.delete_env(:shared_infra, :media_client_adapter),
        else: Application.put_env(:shared_infra, :media_client_adapter, prev.media)
    end)

    :ok
  end

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, email, password_hash, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2, 'x', now(), now())",
      [id, "#{id}@test.local"]
    )

    id
  end

  # A shared active conversation whose participant rows joined `seconds_ago` in the past (so they
  # PREDATE any post made now). Returns the conversation id.
  defp shared_conversation!(a, b, seconds_ago \\ 3600) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, type, created_by, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, 'direct', $2::text::uuid, 'active', now(), now())",
      [id, a]
    )

    for u <- [a, b] do
      Repo.query!(
        "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, 'member', now() - make_interval(secs => $3))",
        [id, u, seconds_ago]
      )
    end

    id
  end

  defp join!(conversation_id, user_id, seconds_ago) do
    Repo.query!(
      "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'member', now() - make_interval(secs => $3))",
      [conversation_id, user_id, seconds_ago]
    )
  end

  defp block!(blocker, blocked) do
    Repo.query!(
      "INSERT INTO user_blocks (blocker_user_id, blocked_user_id) VALUES ($1::text::uuid, $2::text::uuid)",
      [blocker, blocked]
    )
  end

  defmodule FailingPurgeStub do
    @moduledoc false
    def purge_asset(_attrs), do: {:error, :media_unavailable}
  end

  defmodule RaisingPurgeStub do
    @moduledoc false
    # The 2026-09-04 production shape: the message release had no MEDIA_CLIENT_ADAPTER=http, so the
    # default in-process adapter module did not EXIST in that release and every call raised.
    def purge_asset(_attrs), do: raise(UndefinedFunctionError)
  end

  defp expire!(status_id) do
    Repo.query!(
      "UPDATE status_posts SET expires_at = now() - interval '2 hours' WHERE id = $1::text::uuid",
      [status_id]
    )
  end

  defp media_purged_at(status_id) do
    %{rows: [[stamp]]} =
      Repo.query!(
        "SELECT media_purged_at FROM status_posts WHERE id = $1::text::uuid",
        [status_id]
      )

    stamp
  end

  defp post!(owner, overrides \\ %{}) do
    {:ok, post} =
      Statuses.post_status(
        Map.merge(%{"owner_user_id" => owner, "kind" => "text", "body" => "hello"}, overrides)
      )

    post
  end

  defp feed_owners(viewer) do
    {:ok, %{threads: threads}} = Statuses.feed(%{"viewer_user_id" => viewer})
    Enum.map(threads, & &1.owner_user_id)
  end

  defp posts_of(viewer, owner) do
    {:ok, %{posts: posts}} =
      Statuses.list_posts(%{"viewer_user_id" => viewer, "owner_user_id" => owner})

    posts
  end

  defp allowed?(viewer, media_id) do
    {:ok, %{allowed: allowed}} =
      Statuses.media_allowed(%{"viewer_user_id" => viewer, "media_id" => media_id})

    allowed
  end

  # Push a post's created_at into the past. REQUIRED, not a convenience: `now()` is TRANSACTION-frozen
  # and the SQL sandbox runs each test inside ONE transaction, so every `now()` in a test is the SAME
  # instant. The predating rule's strict `me.joined_at < sp.created_at` then sees a TIE and denies —
  # correctly. So a test can never get "the post happened before/after the join" by letting statements
  # run in sequence; the ordering has to be STATED. Backdate the earlier post and join the participant
  # at an offset between it and the later post. (Mirrors expire!/1.)
  defp backdate!(status_id, seconds_ago) do
    Repo.query!(
      "UPDATE status_posts SET created_at = now() - make_interval(secs => $2) WHERE id = $1::text::uuid",
      [status_id, seconds_ago]
    )
  end

  defp expire!(status_id) do
    Repo.query!(
      "UPDATE status_posts SET expires_at = now() - interval '1 second' WHERE id = $1::text::uuid",
      [status_id]
    )
  end

  @tag :postgres_integration
  test "THE PREDATING RULE: contacts from BEFORE the post see it; every retroactive path is closed" do
    owner = user!()
    old_friend = user!()
    shared_conversation!(owner, old_friend)

    post = post!(owner)
    # Anchor the post 10 minutes back so later joins can sit strictly after it (see backdate!/2).
    backdate!(post.status_id, 600)

    # The predating contact sees the thread + posts.
    assert feed_owners(old_friend) == [owner]
    assert [%{body: "hello"}] = posts_of(old_friend, owner)

    # RETROACTIVE PATH 1 — a DM started AFTER the post: the stranger never sees it.
    stranger = user!()
    # Joined 5 min ago — AFTER the post (-600) but BEFORE the second post below (now).
    shared_conversation!(owner, stranger, 300)
    assert feed_owners(stranger) == []
    assert posts_of(stranger, owner) == []

    # RETROACTIVE PATH 2 — a late joiner to a conversation the owner predates.
    late = user!()
    old_group = shared_conversation!(owner, old_friend)
    join!(old_group, late, 0)
    assert feed_owners(late) == []

    # RETROACTIVE PATH 3 — the OWNER joins a group after posting: its members stay outside.
    outsider = user!()
    their_group = shared_conversation!(outsider, user!())
    join!(their_group, owner, 0)
    assert feed_owners(outsider) == []

    # A NEW post after the relationships exist IS visible to all of them (the rule is per-post).
    post2 = post!(owner, %{"body" => "second"})
    assert feed_owners(stranger) == [owner]
    assert Enum.map(posts_of(stranger, owner), & &1.status_id) == [post2.status_id]
    # The old friend sees both.
    assert length(posts_of(old_friend, owner)) == 2
  end

  @tag :postgres_integration
  test "LIVE denies: blocks (both directions) and leaving hide even PREDATING posts" do
    owner = user!()
    friend = user!()
    conversation = shared_conversation!(owner, friend)
    post!(owner)

    assert feed_owners(friend) == [owner]

    # Owner blocks friend → gone, immediately.
    block!(owner, friend)
    assert feed_owners(friend) == []
    Repo.query!("DELETE FROM user_blocks WHERE blocker_user_id = $1::text::uuid", [owner])

    # Friend blocks owner → equally gone (symmetric).
    block!(friend, owner)
    assert feed_owners(friend) == []
    Repo.query!("DELETE FROM user_blocks WHERE blocker_user_id = $1::text::uuid", [friend])

    assert feed_owners(friend) == [owner]

    # Leaving the shared conversation is a live deny too.
    Repo.query!(
      "UPDATE conversation_participants SET left_at = now(), left_reason = 'left' " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [conversation, friend]
    )

    assert feed_owners(friend) == []
  end

  @tag :postgres_integration
  test "EXPIRY is filter-at-read: feed, list, and media_allowed all go dark at expires_at" do
    owner = user!()
    friend = user!()
    shared_conversation!(owner, friend)

    media_id = Ecto.UUID.generate()
    post = post!(owner, %{"kind" => "image", "media_id" => media_id, "body" => nil})

    assert feed_owners(friend) == [owner]
    assert allowed?(friend, media_id)
    assert allowed?(owner, media_id)
    refute allowed?(user!(), media_id)

    expire!(post.status_id)

    assert feed_owners(friend) == []
    assert posts_of(friend, owner) == []
    # The media goes dark WITH the post — even for the owner, even with the id in hand.
    refute allowed?(friend, media_id)
    refute allowed?(owner, media_id)
  end

  @tag :postgres_integration
  test "the owner's OWN list bypasses the audience; delete tombstones + purges immediately" do
    owner = user!()
    media_id = Ecto.UUID.generate()
    post = post!(owner, %{"kind" => "video", "media_id" => media_id})

    # No contacts at all — the owner still sees their own recap.
    assert [%{status_id: status_id}] = posts_of(owner, owner)
    assert status_id == post.status_id

    # Foreign delete → not found; owner delete → gone + object purged NOW.
    assert {:error, :status_not_found} =
             Statuses.delete_status(%{"owner_user_id" => user!(), "status_id" => post.status_id})

    assert {:ok, %{deleted: true}} =
             Statuses.delete_status(%{"owner_user_id" => owner, "status_id" => post.status_id})

    assert posts_of(owner, owner) == []
    assert PurgeStub.purged() == [media_id]
    refute allowed?(owner, media_id)
  end

  @tag :postgres_integration
  test "THE SWEEP: purges expired media (stamping media_purged_at), leaves live posts, deletes >30d rows" do
    owner = user!()
    live_media = Ecto.UUID.generate()
    old_media = Ecto.UUID.generate()

    live = post!(owner, %{"kind" => "image", "media_id" => live_media})
    old = post!(owner, %{"kind" => "image", "media_id" => old_media})
    ancient = post!(owner, %{"body" => "ancient"})

    # `old` expired 2h ago (past the 1h grace); `ancient` expired 31 days ago (past row retention).
    Repo.query!(
      "UPDATE status_posts SET expires_at = now() - interval '2 hours' WHERE id = $1::text::uuid",
      [old.status_id]
    )

    Repo.query!(
      "UPDATE status_posts SET expires_at = now() - interval '31 days' WHERE id = $1::text::uuid",
      [ancient.status_id]
    )

    assert :ok = Statuses.run_sweep()

    # The expired post's object was purged + stamped; the live one untouched; the ancient ROW is gone.
    assert old_media in PurgeStub.purged()
    refute live_media in PurgeStub.purged()

    %{rows: [[purged_count]]} =
      Repo.query!(
        "SELECT count(*)::int FROM status_posts WHERE id = $1::text::uuid AND media_purged_at IS NOT NULL",
        [old.status_id]
      )

    assert purged_count == 1

    %{rows: ancient_rows} =
      Repo.query!("SELECT 1 FROM status_posts WHERE id = $1::text::uuid", [ancient.status_id])

    assert ancient_rows == []
    assert [%{status_id: live_id}] = posts_of(owner, owner)
    assert live_id == live.status_id
  end

  @tag :postgres_integration
  test "validation codes + feed shape (unseen = post_count until commit 2 records views)" do
    owner = user!()
    friend = user!()
    shared_conversation!(owner, friend)

    assert {:error, :status_invalid_kind} =
             Statuses.post_status(%{"owner_user_id" => owner, "kind" => "audio", "body" => "x"})

    assert {:error, :status_invalid_body} =
             Statuses.post_status(%{"owner_user_id" => owner, "kind" => "text", "body" => "  "})

    assert {:error, :status_invalid_body} =
             Statuses.post_status(%{
               "owner_user_id" => owner,
               "kind" => "text",
               "body" => String.duplicate("x", 701)
             })

    assert {:error, :status_media_required} =
             Statuses.post_status(%{"owner_user_id" => owner, "kind" => "image"})

    post!(owner)
    post!(owner, %{"body" => "two"})

    {:ok, %{threads: [thread]}} = Statuses.feed(%{"viewer_user_id" => friend})
    assert thread.post_count == 2
    assert thread.unseen_count == 2
    assert is_binary(thread.latest_at)
  end

  # --- commit 2 helpers ---------------------------------------------------------------------------

  defp set_audience!(user_id, mode, members \\ nil) do
    attrs = %{"user_id" => user_id, "mode" => mode}
    attrs = if members, do: Map.put(attrs, "member_user_ids", members), else: attrs
    {:ok, audience} = Statuses.set_audience(attrs)
    audience
  end

  defp receipts_off!(user_id) do
    Repo.query!(
      "INSERT INTO user_privacy_settings (user_id, last_seen_visibility, profile_photo_visibility, " <>
        "read_receipts_enabled, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, 'contacts', 'contacts', false, now(), now()) " <>
        "ON CONFLICT (user_id) DO UPDATE SET read_receipts_enabled = false",
      [user_id]
    )
  end

  defp view!(status_id, viewer),
    do: Statuses.record_view(%{"status_id" => status_id, "viewer_user_id" => viewer})

  defp viewers_of(status_id, owner) do
    {:ok, result} = Statuses.viewers(%{"status_id" => status_id, "owner_user_id" => owner})
    result
  end

  defp view_rows(status_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT viewer_user_id::text FROM status_views WHERE status_id = $1::text::uuid",
        [status_id]
      )

    Enum.map(rows, &hd/1)
  end

  # --- commit 2 tests -----------------------------------------------------------------------------

  @tag :postgres_integration
  test "AUDIENCE MODES narrow the SAME predicate: 'except' excludes, 'only' restricts (feed + list + media)" do
    owner = user!()
    alice = user!()
    bob = user!()
    shared_conversation!(owner, alice)
    shared_conversation!(owner, bob)

    media_id = Ecto.UUID.generate()
    post = post!(owner, %{"kind" => "image", "media_id" => media_id})

    # Default ('contacts'): both see it, through all three consumers of the predicate.
    assert feed_owners(alice) == [owner]
    assert feed_owners(bob) == [owner]
    assert allowed?(alice, media_id)

    # EXCEPT alice → alice loses it everywhere; bob keeps it.
    set_audience!(owner, "except", [alice])
    assert feed_owners(alice) == []
    assert posts_of(alice, owner) == []
    refute allowed?(alice, media_id)
    assert feed_owners(bob) == [owner]
    assert allowed?(bob, media_id)

    # ONLY alice → the inverse, with no second evaluation path anywhere.
    set_audience!(owner, "only", [alice])
    assert feed_owners(alice) == [owner]
    assert allowed?(alice, media_id)
    assert feed_owners(bob) == []
    refute allowed?(bob, media_id)

    # Back to contacts: the stored list is KEPT but ignored.
    assert %{mode: "contacts", member_user_ids: [^alice]} = set_audience!(owner, "contacts")
    assert feed_owners(bob) == [owner]

    # The owner always sees their own, whatever the mode.
    set_audience!(owner, "only", [])
    assert [%{status_id: sid}] = posts_of(owner, owner)
    assert sid == post.status_id
  end

  @tag :postgres_integration
  test "THE COMPOSITION: an 'only' listee who joined the shared conversation AFTER the post is STILL denied" do
    owner = user!()
    latecomer = user!()

    # The post exists BEFORE any shared conversation with the latecomer (stated explicitly — see
    # backdate!/2: `now()` is frozen for the whole test, so statement order proves nothing).
    before_post = post!(owner)
    backdate!(before_post.status_id, 600)
    # Joined 5 min ago — after that post, before the `fresh` one below.
    shared_conversation!(owner, latecomer, 300)

    # Explicitly listed under 'only' — the mode cannot widen past the predating rule.
    set_audience!(owner, "only", [latecomer])
    assert feed_owners(latecomer) == []
    assert posts_of(latecomer, owner) == []

    # A post made AFTER the relationship IS visible to them (the rule stays per-post).
    fresh = post!(owner, %{"body" => "after"})
    assert Enum.map(posts_of(latecomer, owner), & &1.status_id) == [fresh.status_id]
  end

  @tag :postgres_integration
  test "VIEW RECORDING is gated by the predicate: a BLOCKED viewer provably gets NO row; the owner's own view isn't one" do
    owner = user!()
    friend = user!()
    blocked = user!()
    shared_conversation!(owner, friend)
    shared_conversation!(owner, blocked)

    post = post!(owner)

    # A legitimate viewer records once; a repeat is idempotent (the row is the dedup key).
    assert {:ok, %{recorded: true}} = view!(post.status_id, friend)
    assert {:ok, %{recorded: true}} = view!(post.status_id, friend)
    assert view_rows(post.status_id) == [friend]

    # BLOCKED (either direction) → can't view → can't record → NO ROW EXISTS (asserted, not assumed).
    block!(owner, blocked)
    assert {:error, :status_not_found} = view!(post.status_id, blocked)
    assert view_rows(post.status_id) == [friend]

    # An 'except'-excluded viewer likewise cannot record.
    excluded = user!()
    shared_conversation!(owner, excluded)
    set_audience!(owner, "except", [excluded])
    assert {:error, :status_not_found} = view!(post.status_id, excluded)

    # The OWNER opening their own status is not a view.
    assert {:ok, %{recorded: false}} = view!(post.status_id, owner)
    assert view_rows(post.status_id) == [friend]
  end

  @tag :postgres_integration
  test "VIEWER LIST reciprocity: a receipts-off viewer is ABSENT while their ROW still exists" do
    owner = user!()
    on_viewer = user!()
    off_viewer = user!()
    shared_conversation!(owner, on_viewer)
    shared_conversation!(owner, off_viewer)

    post = post!(owner)
    receipts_off!(off_viewer)

    assert {:ok, %{recorded: true}} = view!(post.status_id, on_viewer)
    assert {:ok, %{recorded: true}} = view!(post.status_id, off_viewer)

    # BOTH rows exist — recording is unconditional; only DISCLOSURE is filtered (read_by_count semantics).
    assert Enum.sort(view_rows(post.status_id)) == Enum.sort([on_viewer, off_viewer])

    result = viewers_of(post.status_id, owner)
    assert Enum.map(result.viewers, & &1.user_id) == [on_viewer]
    assert result.view_count == 1
    refute result.viewers_hidden

    # The OWNER half: with the owner's own receipts off, the list is empty + flagged (their setting).
    receipts_off!(owner)
    hidden = viewers_of(post.status_id, owner)
    assert hidden.viewers == []
    assert hidden.view_count == 0
    assert hidden.viewers_hidden == true
  end

  @tag :postgres_integration
  test "VIEWER LIST is OWNER-ONLY (anyone else → not_found), and my_status carries the distinct view count" do
    owner = user!()
    alice = user!()
    bob = user!()
    shared_conversation!(owner, alice)
    shared_conversation!(owner, bob)

    p1 = post!(owner)
    p2 = post!(owner, %{"body" => "second"})

    # A non-owner can never read a viewer list — even one they appear in.
    assert {:ok, %{recorded: true}} = view!(p1.status_id, alice)

    assert {:error, :status_not_found} =
             Statuses.viewers(%{"status_id" => p1.status_id, "owner_user_id" => alice})

    # my_status: DISTINCT viewers across live posts (alice saw both → counted once).
    assert {:ok, %{recorded: true}} = view!(p2.status_id, alice)
    assert {:ok, %{recorded: true}} = view!(p2.status_id, bob)

    {:ok, mine} = Statuses.my_status(%{"owner_user_id" => owner})
    assert mine.post_count == 2
    assert mine.view_count == 2
    refute mine.viewers_hidden
    assert is_binary(mine.latest_at)

    # No live posts → nil (the feed renders no "My status" entry).
    {:ok, _} = Statuses.delete_status(%{"owner_user_id" => owner, "status_id" => p1.status_id})
    {:ok, _} = Statuses.delete_status(%{"owner_user_id" => owner, "status_id" => p2.status_id})
    assert {:ok, nil} = Statuses.my_status(%{"owner_user_id" => owner})
  end

  @tag :postgres_integration
  test "audience settings: defaults, validation, self+dupes dropped, the cap" do
    owner = user!()
    friend = user!()

    # No row → the default.
    assert {:ok, %{mode: "contacts", member_user_ids: []}} =
             Statuses.get_audience(%{"user_id" => owner})

    assert {:error, :status_invalid_mode} =
             Statuses.set_audience(%{"user_id" => owner, "mode" => "everyone"})

    # Self + duplicates are dropped rather than erroring.
    assert %{mode: "only", member_user_ids: [^friend]} =
             set_audience!(owner, "only", [friend, friend, owner])

    # Absent member list = keep the stored one (a mode-only switch).
    assert %{mode: "except", member_user_ids: [^friend]} = set_audience!(owner, "except")

    too_many = for _ <- 1..257, do: Ecto.UUID.generate()

    assert {:error, :status_audience_limit} =
             Statuses.set_audience(%{
               "user_id" => owner,
               "mode" => "only",
               "member_user_ids" => too_many
             })
  end

  # --- commit 3: replies --------------------------------------------------------------------------

  defp for_reply(status_id, viewer),
    do: Statuses.status_for_reply(%{"status_id" => status_id, "viewer_user_id" => viewer})

  @tag :postgres_integration
  test "REPLY SNAPSHOT is text-only: kind + capped excerpt, never a media pointer" do
    owner = user!()
    friend = user!()
    shared_conversation!(owner, friend)

    text = post!(owner, %{"body" => "  hello there  "})
    assert {:ok, snap} = for_reply(text.status_id, friend)
    assert snap.owner_user_id == owner
    assert snap.kind == "text"
    assert snap.excerpt == "hello there"
    # No thumbnail / media pointer of any kind — the quote can never decay.
    refute Map.has_key?(snap, :thumbnail_media_id)
    refute Map.has_key?(snap, :media_id)

    # An image status quotes its CAPTION; a captionless one quotes nothing (the client renders "Photo").
    captioned =
      post!(owner, %{
        "kind" => "image",
        "media_id" => Ecto.UUID.generate(),
        "body" => "at the beach"
      })

    assert {:ok, %{kind: "image", excerpt: "at the beach"}} =
             for_reply(captioned.status_id, friend)

    bare = post!(owner, %{"kind" => "video", "media_id" => Ecto.UUID.generate(), "body" => nil})
    assert {:ok, %{kind: "video", excerpt: nil}} = for_reply(bare.status_id, friend)

    # Long bodies are capped at 140 + an ellipsis (the snapshot is a quote, not a copy).
    long = post!(owner, %{"body" => String.duplicate("x", 300)})
    assert {:ok, %{excerpt: excerpt}} = for_reply(long.status_id, friend)
    assert String.length(excerpt) == 141
    assert String.ends_with?(excerpt, "…")
  end

  @tag :postgres_integration
  test "THE REPLY-TIME GATE: falling out of the audience turns a viewable status into :status_not_visible" do
    owner = user!()
    friend = user!()
    shared_conversation!(owner, friend)
    post = post!(owner)

    # Openable now.
    assert {:ok, _} = for_reply(post.status_id, friend)

    # Blocked between open and send → a DISTINCT refusal (not_visible), never not_found.
    block!(owner, friend)
    assert {:error, :status_not_visible} = for_reply(post.status_id, friend)
    Repo.query!("DELETE FROM user_blocks WHERE blocker_user_id = $1::text::uuid", [owner])

    # Dropped from an 'only' list between open and send → same distinct refusal.
    set_audience!(owner, "only", [])
    assert {:error, :status_not_visible} = for_reply(post.status_id, friend)
    set_audience!(owner, "contacts")
    assert {:ok, _} = for_reply(post.status_id, friend)

    # A stranger who never qualified gets the SAME not_visible (the post is live) — and an
    # unknown/expired/deleted status is not_found, so nothing distinguishes those two states.
    stranger = user!()
    assert {:error, :status_not_visible} = for_reply(post.status_id, stranger)
    assert {:error, :status_not_found} = for_reply(Ecto.UUID.generate(), friend)

    expire!(post.status_id)
    assert {:error, :status_not_found} = for_reply(post.status_id, friend)
  end

  @tag :postgres_integration
  test "the OWNER may resolve their own status (the gateway refuses the self-reply, not the domain)" do
    owner = user!()
    post = post!(owner)

    # The domain allows it (owner bypass); refusing a DM-with-yourself is the gateway's job — a
    # self-reply would dedupe to ONE participant, skip find_or_create_direct, and orphan a conversation.
    assert {:ok, %{owner_user_id: ^owner}} = for_reply(post.status_id, owner)
  end

  @tag :postgres_integration
  test "the snapshot is INDEPENDENT of the post's later fate (nothing dereferences status_id later)" do
    owner = user!()
    friend = user!()
    shared_conversation!(owner, friend)
    post = post!(owner, %{"body" => "ephemeral thought"})

    assert {:ok, snap} = for_reply(post.status_id, friend)
    assert snap.excerpt == "ephemeral thought"

    # The post dies; the snapshot the caller already holds is unaffected — it is a VALUE, and the only
    # thing that dies is the courtesy pointer (a fresh resolve now 404s, as it must).
    {:ok, _} = Statuses.delete_status(%{"owner_user_id" => owner, "status_id" => post.status_id})
    assert snap.excerpt == "ephemeral thought"
    assert {:error, :status_not_found} = for_reply(post.status_id, friend)
  end

  # --- stamp-after-success ordering (2026-09-04: 22 rows stamped purged, blobs never deleted) ------

  @tag :postgres_integration
  test "a FAILED purge leaves media_purged_at NULL, and the NEXT sweep retries and completes it" do
    owner = user!()
    media = Ecto.UUID.generate()
    post = post!(owner, %{"kind" => "image", "media_id" => media})
    expire!(post.status_id)

    # Sweep 1: the media service is down. The row must NOT be stamped — a stamp here is the leak:
    # it means "blob confirmed gone" while the blob still exists, and nothing ever retries.
    Application.put_env(:shared_infra, :media_client_adapter, FailingPurgeStub)
    assert :ok = Statuses.run_sweep()

    assert media_purged_at(post.status_id) == nil,
           "media_purged_at was stamped BEFORE the purge succeeded — a failed purge is now " <>
             "permanently skipped and the blob leaks forever"

    # Sweep 2: the media service is back. The unstamped row is re-selected, purged, and stamped.
    Application.put_env(:shared_infra, :media_client_adapter, PurgeStub)
    assert :ok = Statuses.run_sweep()

    assert media in PurgeStub.purged()
    refute media_purged_at(post.status_id) == nil
  end

  @tag :postgres_integration
  test "a RAISING purge (the UndefinedFunctionError shape) is isolated per row — sweep survives, row retried" do
    owner = user!()
    media = Ecto.UUID.generate()
    post = post!(owner, %{"kind" => "image", "media_id" => media})
    expire!(post.status_id)

    Application.put_env(:shared_infra, :media_client_adapter, RaisingPurgeStub)
    assert :ok = Statuses.run_sweep()

    assert media_purged_at(post.status_id) == nil
  end

  @tag :postgres_integration
  test "a failed DELETE-path purge is retried by the sweep (deleted rows are now candidates)" do
    owner = user!()
    media = Ecto.UUID.generate()
    post = post!(owner, %{"kind" => "image", "media_id" => media})

    # Owner-delete while the media service is down: the tombstone lands (the user's delete must not
    # fail), the purge fails, the stamp stays NULL.
    Application.put_env(:shared_infra, :media_client_adapter, FailingPurgeStub)

    assert {:ok, %{deleted: true}} =
             Statuses.delete_status(%{"owner_user_id" => owner, "status_id" => post.status_id})

    assert media_purged_at(post.status_id) == nil

    # Before this fix the sweep's `deleted_at IS NULL` filter excluded this row FOREVER. Now the
    # deleted-with-unpurged-media arm selects it regardless of expiry.
    Application.put_env(:shared_infra, :media_client_adapter, PurgeStub)
    assert :ok = Statuses.run_sweep()

    assert media in PurgeStub.purged()
    refute media_purged_at(post.status_id) == nil
  end

  @tag :postgres_integration
  test "a SUCCESSFUL delete-path purge stamps the row, so the sweep never purges it twice" do
    owner = user!()
    media = Ecto.UUID.generate()
    post = post!(owner, %{"kind" => "image", "media_id" => media})

    assert {:ok, %{deleted: true}} =
             Statuses.delete_status(%{"owner_user_id" => owner, "status_id" => post.status_id})

    assert [^media] = PurgeStub.purged()
    refute media_purged_at(post.status_id) == nil

    assert :ok = Statuses.run_sweep()
    assert [^media] = PurgeStub.purged()
  end
end
