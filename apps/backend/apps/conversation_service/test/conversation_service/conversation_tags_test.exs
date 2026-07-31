defmodule ConversationService.ConversationTagsTest do
  @moduledoc """
  CONVERSATION TAGS on real SQL (`@tag :postgres_integration`). Proves: CRUD + the 20-tag cap + the
  50-char name rule; case-insensitive per-owner uniqueness and what rename does; PER-USER ISOLATION
  (my tags are never visible to, nor assignable by, anyone else — asserted, not assumed);
  assignment/unassignment including many tags on one conversation (lists, not folders); that a LEFT
  conversation KEEPS its tags dormant and gets them back on rejoin, matching archive/pin; that
  deleting a tag removes its assignments and touches no conversation; and the QUERY COST of carrying
  tag_ids on the inbox row at the stated scale (20 tags x 500 conversations).
  """
  use ConversationService.DataCase, async: false

  alias ConversationService.{ConversationTags, Conversations}

  @tenant_zero "00000000-0000-0000-0000-000000000001"

  # list_conversations/1 returns placeholders unless persistence is on — without this every inbox
  # assertion below would read a fabricated row instead of the SQL under test.
  setup do
    previous = Application.get_env(:conversation_service, :conversation_persistence, false)
    Application.put_env(:conversation_service, :conversation_persistence, true)

    on_exit(fn ->
      Application.put_env(:conversation_service, :conversation_persistence, previous)
    end)

    :ok
  end

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, email, password_hash, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', now(), now())",
      [id, @tenant_zero, "#{id}@test.local"]
    )

    id
  end

  defp conversation!(creator, members \\ []) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'group', $3::text::uuid, 'active', now(), now())",
      [id, @tenant_zero, creator]
    )

    for u <- [creator | members] do
      Repo.query!(
        "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, 'member', now())",
        [id, u]
      )
    end

    id
  end

  defp leave!(conversation_id, user_id) do
    Repo.query!(
      "UPDATE conversation_participants SET left_at = now() " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [conversation_id, user_id]
    )
  end

  defp rejoin!(conversation_id, user_id) do
    Repo.query!(
      "UPDATE conversation_participants SET left_at = NULL " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [conversation_id, user_id]
    )
  end

  defp tag!(owner, name) do
    {:ok, tag} = ConversationTags.create_tag(%{"owner_user_id" => owner, "name" => name})
    tag
  end

  defp tag_ids_for(user_id, conversation_id) do
    {:ok, %{conversations: rows}} = Conversations.list_conversations(%{"user_id" => user_id})

    case Enum.find(rows, &(&1.conversation_id == conversation_id)) do
      nil -> :not_in_inbox
      row -> row.tag_ids
    end
  end

  # --- CRUD + limits -------------------------------------------------------------------------------

  @tag :postgres_integration
  test "CRUD round-trip: create, list in order, rename, recolour, delete" do
    owner = user!()

    work = tag!(owner, "Work")
    family = tag!(owner, "Family")

    assert work.name == "Work"
    assert work.color == nil
    # position is assigned server-side, ascending.
    assert family.position > work.position

    {:ok, %{tags: tags}} = ConversationTags.list_tags(%{"owner_user_id" => owner})
    assert Enum.map(tags, & &1.name) == ["Work", "Family"]

    {:ok, renamed} =
      ConversationTags.update_tag(%{
        "owner_user_id" => owner,
        "tag_id" => work.tag_id,
        "name" => "  Job  ",
        "color" => "blue"
      })

    # The name is TRIMMED on update exactly as on create.
    assert renamed.name == "Job"
    assert renamed.color == "blue"
    assert renamed.tag_id == work.tag_id

    assert {:ok, %{deleted: true}} =
             ConversationTags.delete_tag(%{"owner_user_id" => owner, "tag_id" => work.tag_id})

    {:ok, %{tags: left}} = ConversationTags.list_tags(%{"owner_user_id" => owner})
    assert Enum.map(left, & &1.name) == ["Family"]
  end

  @tag :postgres_integration
  test "the 20-tag cap and the 50-character name rule are enforced" do
    owner = user!()

    for i <- 1..ConversationTags.tag_limit() do
      assert {:ok, _} =
               ConversationTags.create_tag(%{"owner_user_id" => owner, "name" => "t#{i}"})
    end

    assert {:error, :tag_limit} =
             ConversationTags.create_tag(%{"owner_user_id" => owner, "name" => "one too many"})

    other = user!()
    # The cap is PER USER — another user is unaffected by mine.
    assert {:ok, _} = ConversationTags.create_tag(%{"owner_user_id" => other, "name" => "t1"})

    assert {:error, :tag_invalid} =
             ConversationTags.create_tag(%{"owner_user_id" => other, "name" => ""})

    assert {:error, :tag_invalid} =
             ConversationTags.create_tag(%{"owner_user_id" => other, "name" => "   "})

    at_cap = String.duplicate("a", ConversationTags.max_name())
    assert {:ok, _} = ConversationTags.create_tag(%{"owner_user_id" => other, "name" => at_cap})

    assert {:error, :tag_invalid} =
             ConversationTags.create_tag(%{"owner_user_id" => other, "name" => at_cap <> "a"})
  end

  @tag :postgres_integration
  test "names are unique per owner CASE-INSENSITIVELY; a case-only rename is free" do
    owner = user!()
    tag = tag!(owner, "Work")

    assert {:error, :tag_name_taken} =
             ConversationTags.create_tag(%{"owner_user_id" => owner, "name" => "work"})

    assert {:error, :tag_name_taken} =
             ConversationTags.create_tag(%{"owner_user_id" => owner, "name" => "WORK"})

    # A DIFFERENT user may hold the same name — uniqueness is per owner, not per tenant.
    other = user!()
    assert {:ok, _} = ConversationTags.create_tag(%{"owner_user_id" => other, "name" => "Work"})

    # Case-only edit: same key, so it does not collide with itself.
    assert {:ok, %{name: "WORK"}} =
             ConversationTags.update_tag(%{
               "owner_user_id" => owner,
               "tag_id" => tag.tag_id,
               "name" => "WORK"
             })

    # But renaming ONTO another of my tags still collides.
    second = tag!(owner, "Family")

    assert {:error, :tag_name_taken} =
             ConversationTags.update_tag(%{
               "owner_user_id" => owner,
               "tag_id" => second.tag_id,
               "name" => "work"
             })
  end

  # --- per-user isolation --------------------------------------------------------------------------

  @tag :postgres_integration
  test "PER-USER ISOLATION: my tags are invisible to others and cannot be used by them" do
    me = user!()
    stranger = user!()
    shared = conversation!(me, [stranger])

    mine = tag!(me, "Private")

    {:ok, _} =
      ConversationTags.assign(%{
        "owner_user_id" => me,
        "tag_id" => mine.tag_id,
        "conversation_id" => shared
      })

    # The stranger's tag list does not contain mine.
    {:ok, %{tags: theirs}} = ConversationTags.list_tags(%{"owner_user_id" => stranger})
    assert theirs == []

    # They cannot read, rename, delete, or assign with my tag — all :tag_not_found, never a 403 that
    # would confirm it exists.
    assert {:error, :tag_not_found} =
             ConversationTags.update_tag(%{
               "owner_user_id" => stranger,
               "tag_id" => mine.tag_id,
               "name" => "Hijacked"
             })

    assert {:error, :tag_not_found} =
             ConversationTags.delete_tag(%{"owner_user_id" => stranger, "tag_id" => mine.tag_id})

    assert {:error, :tag_not_found} =
             ConversationTags.assign(%{
               "owner_user_id" => stranger,
               "tag_id" => mine.tag_id,
               "conversation_id" => shared
             })

    # And crucially: the SHARED conversation shows MY tag to me and NOTHING to them, from the same SQL.
    assert tag_ids_for(me, shared) == [mine.tag_id]
    assert tag_ids_for(stranger, shared) == []

    # My tag survived every one of their attempts.
    {:ok, %{tags: still_mine}} = ConversationTags.list_tags(%{"owner_user_id" => me})
    assert Enum.map(still_mine, & &1.name) == ["Private"]
  end

  @tag :postgres_integration
  test "a tag cannot be used to probe conversations the caller is not in" do
    me = user!()
    outsider = user!()
    private = conversation!(me)

    theirs = tag!(outsider, "Fishing")

    assert {:error, :not_participant} =
             ConversationTags.assign(%{
               "owner_user_id" => outsider,
               "tag_id" => theirs.tag_id,
               "conversation_id" => private
             })
  end

  # --- assignment ----------------------------------------------------------------------------------

  @tag :postgres_integration
  test "LISTS NOT FOLDERS: one conversation holds several tags; assign/unassign are idempotent" do
    owner = user!()
    conv = conversation!(owner)
    work = tag!(owner, "Work")
    urgent = tag!(owner, "Urgent")

    assert {:ok, %{tagged: true}} =
             ConversationTags.assign(%{
               "owner_user_id" => owner,
               "tag_id" => work.tag_id,
               "conversation_id" => conv
             })

    assert {:ok, %{tagged: true}} =
             ConversationTags.assign(%{
               "owner_user_id" => owner,
               "tag_id" => urgent.tag_id,
               "conversation_id" => conv
             })

    # BOTH — a conversation is in many lists at once.
    assert Enum.sort(tag_ids_for(owner, conv)) == Enum.sort([work.tag_id, urgent.tag_id])

    # Assigning twice is a no-op, not a duplicate-key error.
    assert {:ok, %{tagged: true}} =
             ConversationTags.assign(%{
               "owner_user_id" => owner,
               "tag_id" => work.tag_id,
               "conversation_id" => conv
             })

    assert length(tag_ids_for(owner, conv)) == 2

    assert {:ok, %{tagged: false}} =
             ConversationTags.unassign(%{
               "owner_user_id" => owner,
               "tag_id" => work.tag_id,
               "conversation_id" => conv
             })

    assert tag_ids_for(owner, conv) == [urgent.tag_id]

    # Unassigning something untagged also succeeds.
    assert {:ok, %{tagged: false}} =
             ConversationTags.unassign(%{
               "owner_user_id" => owner,
               "tag_id" => work.tag_id,
               "conversation_id" => conv
             })
  end

  @tag :postgres_integration
  test "deleting a tag removes its ASSIGNMENTS and touches no conversation" do
    owner = user!()
    conv = conversation!(owner)
    work = tag!(owner, "Work")
    keep = tag!(owner, "Keep")

    {:ok, _} =
      ConversationTags.assign(%{
        "owner_user_id" => owner,
        "tag_id" => work.tag_id,
        "conversation_id" => conv
      })

    {:ok, _} =
      ConversationTags.assign(%{
        "owner_user_id" => owner,
        "tag_id" => keep.tag_id,
        "conversation_id" => conv
      })

    {:ok, _} = ConversationTags.delete_tag(%{"owner_user_id" => owner, "tag_id" => work.tag_id})

    # The assignment went with the tag; the OTHER tag is untouched...
    assert tag_ids_for(owner, conv) == [keep.tag_id]

    # ...and the conversation itself still exists, active, with the caller still a participant.
    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT count(*)::int FROM conversations c JOIN conversation_participants cp " <>
                 "ON cp.conversation_id = c.id AND cp.left_at IS NULL " <>
                 "WHERE c.id = $1::text::uuid AND c.status = 'active' AND cp.user_id = $2::text::uuid",
               [conv, owner]
             )
  end

  # --- left / archived conversations ----------------------------------------------------------------

  @tag :postgres_integration
  test "a LEFT conversation KEEPS its tags dormant and gets them back on rejoin (as archive/pin do)" do
    owner = user!()
    other = user!()
    conv = conversation!(owner, [other])
    work = tag!(owner, "Work")

    {:ok, _} =
      ConversationTags.assign(%{
        "owner_user_id" => owner,
        "tag_id" => work.tag_id,
        "conversation_id" => conv
      })

    assert tag_ids_for(owner, conv) == [work.tag_id]

    leave!(conv, owner)

    # Gone from the inbox entirely (the join filters left_at IS NULL) — the same way a left
    # conversation's archive/pin state becomes invisible rather than being erased.
    assert tag_ids_for(owner, conv) == :not_in_inbox

    # The assignment row was NOT deleted.
    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT count(*)::int FROM conversation_tag_assignments " <>
                 "WHERE tag_id = $1::text::uuid AND conversation_id = $2::text::uuid",
               [work.tag_id, conv]
             )

    # A left conversation cannot gain NEW tags.
    spare = tag!(owner, "Spare")

    assert {:error, :not_participant} =
             ConversationTags.assign(%{
               "owner_user_id" => owner,
               "tag_id" => spare.tag_id,
               "conversation_id" => conv
             })

    rejoin!(conv, owner)
    assert tag_ids_for(owner, conv) == [work.tag_id]
  end

  @tag :postgres_integration
  test "an ARCHIVED conversation keeps its tags and carries them on the archived list" do
    owner = user!()
    conv = conversation!(owner)
    work = tag!(owner, "Work")

    {:ok, _} =
      ConversationTags.assign(%{
        "owner_user_id" => owner,
        "tag_id" => work.tag_id,
        "conversation_id" => conv
      })

    Repo.query!(
      "UPDATE conversation_participants SET archived_at = now() " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [conv, owner]
    )

    # Absent from the default list (archive excludes)...
    assert tag_ids_for(owner, conv) == :not_in_inbox

    # ...but present WITH its tags on the archived list, so the client can filter archived chats by tag.
    {:ok, %{conversations: rows}} =
      Conversations.list_conversations(%{"user_id" => owner, "archived" => true})

    row = Enum.find(rows, &(&1.conversation_id == conv))
    assert row.archived == true
    assert row.tag_ids == [work.tag_id]
  end

  # --- the cost of decision 3 ------------------------------------------------------------------------

  @tag :postgres_integration
  test "THE STATED SCALE: 20 tags x 500 conversations stays ONE query and a bounded payload" do
    owner = user!()
    tags = for i <- 1..20, do: tag!(owner, "tag-#{i}")

    conversations = for _ <- 1..500, do: conversation!(owner)

    # Every conversation in two tags — a realistic heavy user (10 000 would be the pathological
    # every-conversation-in-every-tag case; this is 1 000 assignment rows).
    for {conv, index} <- Enum.with_index(conversations) do
      for tag <- [Enum.at(tags, rem(index, 20)), Enum.at(tags, rem(index + 1, 20))] do
        Repo.query!(
          "INSERT INTO conversation_tag_assignments (tag_id, conversation_id) " <>
            "VALUES ($1::text::uuid, $2::text::uuid) ON CONFLICT DO NOTHING",
          [tag.tag_id, conv]
        )
      end
    end

    # THE COST CLAIM: carrying tag_ids adds a lateral to the EXISTING inbox query — it does not add a
    # query, and it does not add one per conversation. Count the queries the whole listing takes.
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:conversation_service, :repo, :query],
      fn _e, _m, _meta, _c -> send(parent, {:q, ref}) end,
      nil
    )

    {:ok, %{conversations: rows}} = Conversations.list_conversations(%{"user_id" => owner})
    :telemetry.detach({__MODULE__, ref})

    queries =
      Enum.reduce_while(1..10_000, 0, fn _, acc ->
        receive do
          {:q, ^ref} -> {:cont, acc + 1}
        after
          0 -> {:halt, acc}
        end
      end)

    assert length(rows) == 500
    assert queries == 1, "the inbox must stay ONE query regardless of tag count, got #{queries}"

    # Every row carries exactly its own two tags — the payload is bounded by ASSIGNMENTS (1 000 ids),
    # never by conversations x tags (which would be 10 000 here).
    total_ids = rows |> Enum.map(&length(&1.tag_ids)) |> Enum.sum()
    assert total_ids == 1_000
    assert Enum.all?(rows, &(length(&1.tag_ids) == 2))
  end

  @tag :postgres_integration
  test "a conversation with NO tags carries an empty list, never nil" do
    owner = user!()
    conv = conversation!(owner)

    assert tag_ids_for(owner, conv) == []
  end
end
