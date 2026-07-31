defmodule ConversationService.BroadcastListsTest do
  @moduledoc """
  Broadcast-list storage (`@tag :postgres_integration`): CRUD with OWNER scoping (foreign list →
  :list_not_found), the member/list caps with their codes, member validation (cross-tenant + suspended +
  self rejected at ADD; dupes collapsed), member REPLACE semantics, the send-time filter (suspended
  members in member_ids but NOT sendable_member_ids), and the lifecycle prunes: a HARD-deleted user's
  membership cascades away; deleting a list cascades its members.
  """
  use ConversationService.DataCase, async: false

  alias ConversationService.BroadcastLists

  @tenant_zero "00000000-0000-0000-0000-000000000001"

  setup do
    previous = Application.get_env(:conversation_service, :conversation_persistence, false)
    Application.put_env(:conversation_service, :conversation_persistence, true)

    on_exit(fn ->
      Application.put_env(:conversation_service, :conversation_persistence, previous)
    end)

    :ok
  end

  defp user!(opts \\ []) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, email, password_hash, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', $4, now(), now())",
      [id, opts[:app_id] || @tenant_zero, "#{id}@test.local", opts[:status] || "active"]
    )

    id
  end

  defp app! do
    id = Ecto.UUID.generate()

    Repo.query!("INSERT INTO apps (id, name, slug) VALUES ($1::text::uuid, 'T', $2)", [
      id,
      "t-#{id}"
    ])

    id
  end

  defp create!(owner, name, members),
    do:
      BroadcastLists.create_list(%{
        "owner_user_id" => owner,
        "name" => name,
        "member_user_ids" => members
      })

  @tag :postgres_integration
  test "CRUD round-trip with OWNER scoping; delete cascades members" do
    owner = user!()
    stranger = user!()
    [m1, m2] = [user!(), user!()]

    assert {:ok, %{list_id: list_id, name: "Friends", member_count: 2}} =
             create!(owner, "  Friends  ", [m1, m2])

    assert {:ok, %{lists: [%{list_id: ^list_id, member_count: 2}]}} =
             BroadcastLists.list_lists(%{"owner_user_id" => owner})

    # Foreign access → not found for get/update/delete (no existence leak).
    for op <- [:get_list, :update_list, :delete_list] do
      assert {:error, :list_not_found} =
               apply(BroadcastLists, op, [%{"owner_user_id" => stranger, "list_id" => list_id}])
    end

    # Rename keeps members; member REPLACE swaps the whole set.
    assert {:ok, %{name: "Team", member_count: 2}} =
             BroadcastLists.update_list(%{
               "owner_user_id" => owner,
               "list_id" => list_id,
               "name" => "Team"
             })

    m3 = user!()

    assert {:ok, %{member_count: 1}} =
             BroadcastLists.update_list(%{
               "owner_user_id" => owner,
               "list_id" => list_id,
               "member_user_ids" => [m3]
             })

    assert {:ok, %{member_ids: [^m3]}} =
             BroadcastLists.get_list(%{"owner_user_id" => owner, "list_id" => list_id})

    assert {:ok, %{deleted: true}} =
             BroadcastLists.delete_list(%{"owner_user_id" => owner, "list_id" => list_id})

    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*)::int FROM broadcast_list_members WHERE list_id = $1::text::uuid",
        [list_id]
      )

    assert count == 0
  end

  @tag :postgres_integration
  test "member validation: cross-tenant, suspended, unknown rejected; SELF and dupes silently dropped" do
    owner = user!()
    ok_member = user!()
    other_app = app!()
    cross = user!(app_id: other_app)
    suspended = user!(status: "suspended")

    assert {:error, :invalid_member} = create!(owner, "L", [ok_member, cross])
    assert {:error, :invalid_member} = create!(owner, "L", [ok_member, suspended])
    assert {:error, :invalid_member} = create!(owner, "L", [ok_member, Ecto.UUID.generate()])

    # Self + duplicates collapse rather than erroring (you can't broadcast to yourself).
    assert {:ok, %{member_count: 1}} = create!(owner, "L", [ok_member, ok_member, owner])
  end

  @tag :postgres_integration
  test "caps carry their codes: 256 members, 32 lists; name validation" do
    owner = user!()
    member = user!()

    too_many = for _ <- 1..257, do: Ecto.UUID.generate()
    assert {:error, :member_limit} = create!(owner, "L", too_many)

    assert {:error, :invalid_name} = create!(owner, "   ", [member])
    assert {:error, :invalid_name} = create!(owner, String.duplicate("x", 101), [member])

    for i <- 1..32, do: {:ok, _} = create!(owner, "List #{i}", [member])
    assert {:error, :list_limit} = create!(owner, "One too many", [member])
  end

  @tag :postgres_integration
  test "SUSPENDED member: filtered from sendable_member_ids (kept on the list); DELETED member: pruned by cascade" do
    owner = user!()
    healthy = user!()
    fades = user!()
    vanishes = user!()

    assert {:ok, %{list_id: list_id}} = create!(owner, "L", [healthy, fades, vanishes])

    # Suspend one (reversible → kept, filtered), hard-delete another (pruned by FK cascade).
    Repo.query!("UPDATE users_auth SET status = 'suspended' WHERE id = $1::text::uuid", [fades])
    Repo.query!("DELETE FROM users_auth WHERE id = $1::text::uuid", [vanishes])

    assert {:ok, list} =
             BroadcastLists.get_list(%{"owner_user_id" => owner, "list_id" => list_id})

    # The deleted member is GONE from the list; the suspended one is present but not sendable.
    assert Enum.sort(list.member_ids) == Enum.sort([healthy, fades])
    assert list.sendable_member_ids == [healthy]

    # Reactivation restores sendability — nothing was destroyed.
    Repo.query!("UPDATE users_auth SET status = 'active' WHERE id = $1::text::uuid", [fades])

    assert {:ok, %{sendable_member_ids: sendable}} =
             BroadcastLists.get_list(%{"owner_user_id" => owner, "list_id" => list_id})

    assert Enum.sort(sendable) == Enum.sort([healthy, fades])
  end
end
