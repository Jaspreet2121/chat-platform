defmodule MessageService.StatusesTest do
  @moduledoc """
  Status commit 1 on real SQL (`@tag :postgres_integration`). Proves: THE PREDATING AUDIENCE RULE (a
  conversation started AFTER the post admits nobody; a late group joiner sees nothing; the OWNER joining
  a group after posting doesn't retroactively admit that group; predating contacts see everything);
  blocks deny live in both directions; leaving denies live; expiry is filter-at-read (feed, list, and
  media_allowed all go dark at expires_at); the owner's own list bypasses the audience; owner-delete
  tombstones + purges immediately; and THE SWEEP (run inline — the async task can't share the SQL
  sandbox) purges expired media, stamps media_purged_at, and hard-deletes >30-day rows.
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

    # The predating contact sees the thread + posts.
    assert feed_owners(old_friend) == [owner]
    assert [%{body: "hello"}] = posts_of(old_friend, owner)

    # RETROACTIVE PATH 1 — a DM started AFTER the post: the stranger never sees it.
    stranger = user!()
    shared_conversation!(owner, stranger, 0)
    # (joined now, post created moments ago → joined_at > created_at)
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
end
