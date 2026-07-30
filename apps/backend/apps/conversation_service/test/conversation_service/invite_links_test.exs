defmodule ConversationService.InviteLinksTest do
  @moduledoc """
  Group invite links (`@tag :postgres_integration`; the logic is SQL). Covers owner-only management, the
  one-active-link-per-conversation invariant, revoke/reset, the join cases (fresh → participant row / already
  member → idempotent / removed → refused / revoked+unknown → not found), app-scoping, and the preview shape.
  Fixtures mirror the raw-SQL style of the other conversation_service integration tests.
  """
  use ConversationService.DataCase, async: false

  alias ConversationService.{InviteLinks, InviteLinkStore}

  @app_id "00000000-0000-0000-0000-000000000001"
  @other_app "00000000-0000-0000-0000-0000000000ff"

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

  # A group owned by `owner`, in `app_id` (default the main tenant).
  defp group!(owner, opts \\ []) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, type, title, created_by, status, app_id, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, 'group', $2, $3::text::uuid, 'active', $4::text::uuid, now(), now())",
      [id, opts[:title] || "Test Group", owner, opts[:app_id] || @app_id]
    )

    participant!(id, owner, "owner", opts[:app_id] || @app_id)
    id
  end

  defp participant!(conversation_id, user_id, role, app_id \\ @app_id) do
    Repo.query!(
      "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at, app_id) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, now(), $4::text::uuid)",
      [conversation_id, user_id, role, app_id]
    )
  end

  # A row REMOVED by moderation (left_reason='removed', 078) — refused by a live link.
  defp removed_participant!(conversation_id, user_id), do: left_participant!(conversation_id, user_id, "removed")

  # A row that LEFT voluntarily (left_reason='left', 078) — a live link reactivates it.
  defp left_participant!(conversation_id, user_id, reason) do
    Repo.query!(
      "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at, left_at, left_reason, app_id) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'member', now(), now(), $3, $4::text::uuid)",
      [conversation_id, user_id, reason, @app_id]
    )
  end

  defp active_participant(conversation_id, user_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT role FROM conversation_participants " <>
          "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid AND left_at IS NULL",
        [conversation_id, user_id]
      )

    case rows do
      [[role]] -> role
      _ -> nil
    end
  end

  defp create(conversation_id, actor),
    do: InviteLinks.create_link(%{"conversation_id" => conversation_id, "actor_user_id" => actor})

  defp join(code, user_id, app_id \\ @app_id),
    do: InviteLinks.join_link(%{"code" => code, "user_id" => user_id, "app_id" => app_id})

  @tag :postgres_integration
  test "create is OWNER-ONLY and idempotent (one active link per conversation)" do
    owner = user!("owner")
    admin = user!("admin")
    member = user!("member")
    g = group!(owner)
    participant!(g, admin, "admin")
    participant!(g, member, "member")

    # A member and an admin cannot mint — member-adding is owner-controlled.
    assert {:error, :not_owner} = create(g, member)
    assert {:error, :not_owner} = create(g, admin)

    # The owner mints; a second create returns the SAME code (one active link).
    assert {:ok, %{code: code1}} = create(g, owner)
    assert is_binary(code1) and byte_size(code1) >= 20
    assert {:ok, %{code: ^code1}} = create(g, owner)

    # Exactly one active row in the store.
    assert %{code: ^code1} = InviteLinkStore.get_active_by_conversation(g)
  end

  @tag :postgres_integration
  test "revoke invalidates the code immediately; reset revokes + mints a new one" do
    owner = user!("owner")
    joiner = user!("joiner")
    g = group!(owner)

    assert {:ok, %{code: code}} = create(g, owner)

    # Reset → a NEW code; the OLD one no longer resolves.
    assert {:ok, %{code: code2}} = InviteLinks.reset_link(%{"conversation_id" => g, "actor_user_id" => owner})
    assert code2 != code
    assert {:error, :link_not_found} = join(code, joiner)

    # Revoke the new one → it too stops resolving.
    assert {:ok, %{revoked: true}} = InviteLinks.revoke_link(%{"conversation_id" => g, "actor_user_id" => owner})
    assert {:error, :link_not_found} = join(code2, joiner)
    assert InviteLinkStore.get_active_by_conversation(g) == nil

    # Revoke is owner-only too.
    assert {:ok, %{code: _}} = create(g, owner)
    stranger = user!("stranger")
    assert {:error, :not_owner} = InviteLinks.revoke_link(%{"conversation_id" => g, "actor_user_id" => stranger})
  end

  @tag :postgres_integration
  test "join: fresh join adds a member row; already-member is idempotent; removed is refused" do
    owner = user!("owner")
    joiner = user!("joiner")
    removed = user!("removed")
    g = group!(owner)
    removed_participant!(g, removed)

    assert {:ok, %{code: code}} = create(g, owner)

    # Fresh join → a member participant row.
    refute active_participant(g, joiner)
    assert {:ok, %{status: "joined", conversation_id: ^g, role: "member"}} = join(code, joiner)
    assert active_participant(g, joiner) == "member"

    # Joining again → idempotent, no duplicate, reports their existing role.
    assert {:ok, %{status: "already_member", role: "member"}} = join(code, joiner)
    # The owner joining their own link → already a member (as owner).
    assert {:ok, %{status: "already_member", role: "owner"}} = join(code, owner)

    # A REMOVED user cannot walk back in via the live link (§4 option b — left_reason='removed').
    assert {:error, :removed} = join(code, removed)
    refute active_participant(g, removed)
  end

  @tag :postgres_integration
  test "a VOLUNTARY leaver (left_reason='left') rejoins via a live link — reactivated as a fresh member" do
    owner = user!("owner")
    leaver = user!("leaver")
    g = group!(owner)
    # An ex-ADMIN who left voluntarily: reactivation must demote to member (roles aren't retained).
    left_participant!(g, leaver, "left")
    Repo.query!(
      "UPDATE conversation_participants SET role = 'admin' WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [g, leaver]
    )

    assert {:ok, %{code: code}} = InviteLinks.create_link(%{"conversation_id" => g, "actor_user_id" => owner})

    assert {:ok, %{status: "joined", conversation_id: ^g, role: "member"}} = join(code, leaver)
    # One row, active again, as MEMBER (role + left markers reset).
    assert active_participant(g, leaver) == "member"

    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*)::int FROM conversation_participants WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
        [g, leaver]
      )

    assert count == 1
  end

  @tag :postgres_integration
  test "an unknown code and a cross-tenant code both → link_not_found" do
    owner = user!("owner")
    joiner = user!("joiner")
    g = group!(owner)
    assert {:ok, %{code: code}} = create(g, owner)

    assert {:error, :link_not_found} = join("totally-unknown-code", joiner)
    # A valid code, wrong tenant → invisible (app-scoped).
    assert {:error, :link_not_found} = join(code, joiner, @other_app)
    assert {:error, :link_not_found} = InviteLinks.preview_link(%{"code" => code, "app_id" => @other_app})
  end

  @tag :postgres_integration
  test "preview exposes exactly name, avatar media id, and the ACTIVE member count" do
    owner = user!("owner")
    member = user!("member")
    g = group!(owner, title: "Design Team")
    participant!(g, member, "member")

    assert {:ok, %{code: code}} = create(g, owner)

    assert {:ok, preview} = InviteLinks.preview_link(%{"code" => code, "app_id" => @app_id})
    assert preview.name == "Design Team"
    assert preview.member_count == 2
    # The shape is exactly the three preview fields (avatar id is nil here; the gateway presigns it).
    assert Map.keys(preview) |> Enum.sort() == [:group_avatar_media_id, :member_count, :name]
  end
end
