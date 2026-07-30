defmodule ConversationService.LeaveConversationTest do
  @moduledoc """
  Voluntary leave (078) — `@tag :postgres_integration`. Covers: a member leaving (left_reason='left', gone
  from their inbox list, others untouched); an admin leaving (no transfer); the OWNER leaving (ownership →
  oldest admin, else oldest member; response carries new_owner_user_id); the LAST participant leaving
  (conversation archived → a live invite link dies); groups-only (direct → :not_a_group); owner RE-ADD
  reactivating a left row for BOTH reasons (deliberate override, unlike a link walk-in); and that a
  moderation removal still writes left_reason='removed'.
  """
  use ConversationService.DataCase, async: false

  alias ConversationService.{Conversations, InviteLinks, Participants}

  @app_id "00000000-0000-0000-0000-000000000001"

  setup do
    previous = Application.get_env(:conversation_service, :conversation_persistence, false)
    Application.put_env(:conversation_service, :conversation_persistence, true)
    on_exit(fn -> Application.put_env(:conversation_service, :conversation_persistence, previous) end)
    :ok
  end

  defp user!(name) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, email, password_hash, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', now(), now())",
      [id, @app_id, "#{name}-#{id}@test.local"]
    )

    id
  end

  defp conversation!(created_by, type) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, type, title, created_by, status, app_id, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2, 'T', $3::text::uuid, 'active', $4::text::uuid, now(), now())",
      [id, type, created_by, @app_id]
    )

    id
  end

  # seconds_offset staggers joined_at so "oldest" is deterministic in the transfer tests.
  defp participant!(conversation_id, user_id, role, seconds_ago \\ 0) do
    Repo.query!(
      "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at, app_id) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, now() - make_interval(secs => $4), $5::text::uuid)",
      [conversation_id, user_id, role, seconds_ago, @app_id]
    )
  end

  defp row(conversation_id, user_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT role, (left_at IS NOT NULL), left_reason FROM conversation_participants " <>
          "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
        [conversation_id, user_id]
      )

    case rows do
      [[role, left?, reason]] -> %{role: role, left: left?, reason: reason}
      _ -> nil
    end
  end

  defp conversation_status(conversation_id) do
    %{rows: [[status]]} =
      Repo.query!("SELECT status FROM conversations WHERE id = $1::text::uuid", [conversation_id])

    status
  end

  defp leave(conversation_id, user_id),
    do: Participants.leave_conversation(%{"conversation_id" => conversation_id, "user_id" => user_id})

  defp inbox_ids(user_id) do
    {:ok, %{conversations: conversations}} = Conversations.list_conversations(%{"user_id" => user_id})
    Enum.map(conversations, & &1.conversation_id)
  end

  @tag :postgres_integration
  test "a MEMBER leaves: left_reason='left', gone from THEIR list, the others untouched" do
    owner = user!("owner")
    member = user!("member")
    g = conversation!(owner, "group")
    participant!(g, owner, "owner", 100)
    participant!(g, member, "member")
    # a message so the conversation shows in inbox lists
    Repo.query!(
      "INSERT INTO messages (message_id, conversation_id, sender_user_id, message_type, body, status, created_at, app_id) " <>
        "VALUES (gen_random_uuid(), $1::text::uuid, $2::text::uuid, 'text', 'hi', 'active', now(), $3::text::uuid)",
      [g, owner, @app_id]
    )

    assert {:ok, %{left: true, conversation_archived: false} = result} = leave(g, member)
    refute Map.has_key?(result, :new_owner_user_id)

    assert %{left: true, reason: "left"} = row(g, member)
    refute g in inbox_ids(member)
    assert g in inbox_ids(owner)
    # The owner keeps their role; the conversation stays active.
    assert %{role: "owner", left: false} = row(g, owner)
    assert conversation_status(g) == "active"
  end

  @tag :postgres_integration
  test "an ADMIN leaves: no transfer, owner unchanged" do
    owner = user!("owner")
    admin = user!("admin")
    g = conversation!(owner, "group")
    participant!(g, owner, "owner", 100)
    participant!(g, admin, "admin")

    assert {:ok, result} = leave(g, admin)
    refute Map.has_key?(result, :new_owner_user_id)
    assert %{role: "owner", left: false} = row(g, owner)
    assert %{left: true, reason: "left"} = row(g, admin)
  end

  @tag :postgres_integration
  test "the OWNER leaves: ownership → the OLDEST ADMIN (else oldest member); response says who" do
    owner = user!("owner")
    old_admin = user!("old-admin")
    new_admin = user!("new-admin")
    member = user!("member")
    g = conversation!(owner, "group")
    participant!(g, owner, "owner", 300)
    participant!(g, old_admin, "admin", 200)
    participant!(g, new_admin, "admin", 100)
    participant!(g, member, "member", 250)

    assert {:ok, %{left: true, new_owner_user_id: ^old_admin}} = leave(g, owner)
    assert %{role: "owner", left: false} = row(g, old_admin)
    assert %{role: "admin", left: false} = row(g, new_admin)
    assert %{left: true, reason: "left"} = row(g, owner)

    # No admins left: the NEXT owner leaving hands off to the oldest MEMBER.
    assert {:ok, _} = leave(g, new_admin)
    assert {:ok, %{new_owner_user_id: ^member}} = leave(g, old_admin)
    assert %{role: "owner", left: false} = row(g, member)
  end

  @tag :postgres_integration
  test "the LAST participant leaves: conversation archived, a live invite link DIES" do
    owner = user!("owner")
    g = conversation!(owner, "group")
    participant!(g, owner, "owner")
    joiner = user!("joiner")

    assert {:ok, %{code: code}} =
             InviteLinks.create_link(%{"conversation_id" => g, "actor_user_id" => owner})

    assert {:ok, %{left: true, conversation_archived: true} = result} = leave(g, owner)
    # Sole participant: nothing to transfer to.
    refute Map.has_key?(result, :new_owner_user_id)
    assert conversation_status(g) == "archived"

    # The live code no longer admits anyone (no ownerless walk-ins).
    assert {:error, :link_not_found} =
             InviteLinks.join_link(%{"code" => code, "user_id" => joiner, "app_id" => @app_id})
  end

  @tag :postgres_integration
  test "GROUPS ONLY: leaving a direct chat → :not_a_group; a non-member → :participant_not_found" do
    a = user!("a")
    b = user!("b")
    d = conversation!(a, "direct")
    participant!(d, a, "member")
    participant!(d, b, "member")

    assert {:error, :not_a_group} = leave(d, a)

    g = conversation!(a, "group")
    participant!(g, a, "owner")
    stranger = user!("stranger")
    assert {:error, :participant_not_found} = leave(g, stranger)
  end

  @tag :postgres_integration
  test "owner RE-ADD reactivates a left row for BOTH reasons (moderation removal writes 'removed')" do
    owner = user!("owner")
    removed = user!("removed")
    leaver = user!("leaver")
    g = conversation!(owner, "group")
    participant!(g, owner, "owner", 100)
    participant!(g, removed, "member")
    participant!(g, leaver, "member")

    # The moderation removal writes left_reason='removed'.
    assert {:ok, _} =
             Participants.remove_participant(%{
               "conversation_id" => g,
               "user_id" => removed,
               "actor_user_id" => owner
             })

    assert %{left: true, reason: "removed"} = row(g, removed)

    # A voluntary leave writes 'left'.
    assert {:ok, _} = leave(g, leaver)
    assert %{left: true, reason: "left"} = row(g, leaver)

    # The OWNER re-adding reactivates BOTH (deliberate override, unlike a link walk-in).
    for target <- [removed, leaver] do
      assert {:ok, _} =
               Participants.add_participant(%{
                 "conversation_id" => g,
                 "user_id" => target,
                 "actor_user_id" => owner
               })

      assert %{role: "member", left: false, reason: nil} = row(g, target)
    end
  end
end
