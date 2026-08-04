defmodule UserService.FavouriteContactsTest do
  @moduledoc """
  FAVOURITE CONTACTS (090) on real SQL. Proves: CRUD + the 20-cap; PER-USER ISOLATION asserted from
  both sides; a hard-DELETED favourite's row is GONE (FK CASCADE — the broadcast_list_members
  decision); a SUSPENDED one is filtered at read while its row survives (the broadcast-send
  decision); self-favouriting refused; unknown/cross-tenant targets refused identically; ordering
  user-controlled, reorder tolerant of ids removed on another device; add/remove idempotent.
  """
  use UserService.DataCase, async: false

  alias UserService.FavouriteContacts

  @tenant_zero "00000000-0000-0000-0000-000000000001"

  defp user!(app_id \\ @tenant_zero) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, email, password_hash, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', 'active', now(), now())",
      [id, app_id, "#{id}@test.local"]
    )

    id
  end

  defp add!(owner, target) do
    {:ok, _} =
      FavouriteContacts.add(%{"owner_user_id" => owner, "favourite_user_id" => target})
  end

  defp ids(owner) do
    {:ok, %{favourites: favourites}} = FavouriteContacts.list(%{"owner_user_id" => owner})
    Enum.map(favourites, & &1.user_id)
  end

  @tag :postgres_integration
  test "CRUD + ordering: added in order, re-add idempotent, remove idempotent" do
    owner = user!()
    [a, b, c] = for _ <- 1..3, do: user!()

    add!(owner, a)
    add!(owner, b)
    add!(owner, c)
    assert ids(owner) == [a, b, c]

    # Re-favouriting keeps the existing row AND its position (ON CONFLICT DO NOTHING).
    add!(owner, a)
    assert ids(owner) == [a, b, c]

    {:ok, %{favourited: false}} =
      FavouriteContacts.remove(%{"owner_user_id" => owner, "favourite_user_id" => b})

    assert ids(owner) == [a, c]

    # Removing a non-favourite succeeds (another device may have removed it first).
    {:ok, %{favourited: false}} =
      FavouriteContacts.remove(%{"owner_user_id" => owner, "favourite_user_id" => b})
  end

  @tag :postgres_integration
  test "REORDER: full order applied; ids removed elsewhere are ignored; unlisted rows sink" do
    owner = user!()
    [a, b, c] = for _ <- 1..3, do: user!()
    add!(owner, a)
    add!(owner, b)
    add!(owner, c)

    ghost = Ecto.UUID.generate()

    {:ok, %{favourites: reordered}} =
      FavouriteContacts.reorder(%{
        "owner_user_id" => owner,
        # c first, a second; the ghost id (removed on another device) must not fail the call; b is
        # unlisted and sinks below the reordered ones.
        "favourite_user_ids" => [c, ghost, a]
      })

    listed = Enum.map(reordered, & &1.user_id)
    assert listed == [c, a, b]
  end

  @tag :postgres_integration
  test "the 20-favourite cap is enforced per user; another user is unaffected" do
    owner = user!()

    for _ <- 1..FavouriteContacts.limit() do
      add!(owner, user!())
    end

    assert {:error, :favourite_limit} =
             FavouriteContacts.add(%{
               "owner_user_id" => owner,
               "favourite_user_id" => user!()
             })

    other = user!()
    add!(other, user!())
    assert length(ids(other)) == 1
  end

  @tag :postgres_integration
  test "PER-USER ISOLATION from both sides: my list is mine; being favourited reveals nothing" do
    me = user!()
    them = user!()
    shared_target = user!()

    add!(me, shared_target)

    # Their list is empty — my favourite is invisible to them.
    assert ids(them) == []

    # They favourite the same target: two independent rows, independently ordered and removed.
    add!(them, shared_target)

    {:ok, _} =
      FavouriteContacts.remove(%{"owner_user_id" => them, "favourite_user_id" => shared_target})

    assert ids(them) == []
    assert ids(me) == [shared_target]
  end

  @tag :postgres_integration
  test "a hard-DELETED favourite's row is GONE (FK cascade); a SUSPENDED one is filtered, row kept" do
    owner = user!()
    deleted = user!()
    suspended = user!()
    keeper = user!()

    add!(owner, deleted)
    add!(owner, suspended)
    add!(owner, keeper)

    Repo.query!("DELETE FROM users_auth WHERE id = $1::text::uuid", [deleted])

    Repo.query!("UPDATE users_auth SET status = 'suspended' WHERE id = $1::text::uuid", [
      suspended
    ])

    # Deleted: pruned by CASCADE. Suspended: absent from the READ...
    assert ids(owner) == [keeper]

    # ...but its ROW survives (suspension is reversible — reinstating restores the favourite).
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*)::int FROM favourite_contacts " <>
          "WHERE owner_user_id = $1::text::uuid AND favourite_user_id = $2::text::uuid",
        [owner, suspended]
      )

    assert count == 1

    Repo.query!("UPDATE users_auth SET status = 'active' WHERE id = $1::text::uuid", [suspended])
    assert suspended in ids(owner)
  end

  @tag :postgres_integration
  test "self-favouriting and unknown/cross-tenant targets are refused" do
    owner = user!()

    assert {:error, :favourite_invalid} =
             FavouriteContacts.add(%{"owner_user_id" => owner, "favourite_user_id" => owner})

    assert {:error, :favourite_unknown_user} =
             FavouriteContacts.add(%{
               "owner_user_id" => owner,
               "favourite_user_id" => Ecto.UUID.generate()
             })

    # Cross-tenant: the target EXISTS but in another app — the SAME answer, no probe.
    other_app = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO apps (id, name, slug) VALUES ($1::text::uuid, 'Other', $2)",
      [other_app, "oth-" <> String.slice(String.replace(other_app, "-", ""), 0, 12)]
    )

    foreign = user!(other_app)

    assert {:error, :favourite_unknown_user} =
             FavouriteContacts.add(%{"owner_user_id" => owner, "favourite_user_id" => foreign})
  end
end
