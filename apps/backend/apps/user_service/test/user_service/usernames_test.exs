defmodule UserService.UsernamesTest do
  @moduledoc """
  Username lifecycle on real SQL (`@tag :postgres_integration`): set/change/remove through the PATCH /me
  path; case-insensitive per-tenant uniqueness (Alice vs alice) with normalisation applied on write AND
  lookup; TWO tenants holding the same handle with lookup never crossing; the @a → @b → @a sequence
  (reclaim costs a change, the budget refunds NOTHING — holds are never deleted); case-only edits FREE
  even with the budget exhausted; holds blocking strangers while the vacating owner reclaims; removal
  writing a hold; ACTIVE-only resolution asserted in PARITY with the phone lookup on the same suspended
  user; and availability (taken / held / invalid / own-handle-free).
  """
  use UserService.DataCase, async: false

  alias UserService.{Profiles, Usernames}

  @tenant_zero "00000000-0000-0000-0000-000000000001"

  setup do
    prev = Application.get_env(:user_service, :user_profile_persistence, false)
    Application.put_env(:user_service, :user_profile_persistence, true)
    on_exit(fn -> Application.put_env(:user_service, :user_profile_persistence, prev) end)
    :ok
  end

  defp user!(app_id \\ @tenant_zero) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, password_hash, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', now(), now())",
      [id, app_id, "+1#{System.unique_integer([:positive])}"]
    )

    Repo.query!(
      "INSERT INTO user_profiles (user_id, display_name, app_id, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, 'Test User', $2::text::uuid, now(), now())",
      [id, app_id]
    )

    id
  end

  defp app! do
    id = Ecto.UUID.generate()
    Repo.query!("INSERT INTO apps (id, name, slug) VALUES ($1::text::uuid, 'T', $2)", [id, "t-#{id}"])
    id
  end

  defp set!(user_id, username),
    do: Usernames.set_username(%{"user_id" => user_id, "username" => username})

  defp lookup(username, app_id \\ @tenant_zero),
    do: Usernames.lookup(%{"username" => username, "app_id" => app_id})

  defp hold_count(user_id) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*)::int FROM username_holds WHERE user_id = $1::text::uuid", [user_id])

    n
  end

  @tag :postgres_integration
  test "set via PATCH /me path: first set is FREE (no hold); the profile card + /me carry the handle" do
    u = user!()

    assert {:ok, updated} =
             Profiles.update_current_profile(%{"user_id" => u, "username" => "Alice_99"})

    assert updated.username == "Alice_99"
    assert hold_count(u) == 0

    # /me and the public card both carry it; lookup resolves ANY casing to the same user.
    assert {:ok, %{username: "Alice_99"}} = Profiles.get_current_profile(%{"user_id" => u})

    assert {:ok, %{username: "Alice_99"}} =
             Profiles.get_public_profile(%{"user_id" => u, "app_id" => @tenant_zero})

    assert {:ok, %{user_id: ^u}} = lookup("ALICE_99")
  end

  @tag :postgres_integration
  test "case-insensitive collision: Alice is taken, alice is :username_taken for someone else" do
    a = user!()
    b = user!()

    assert {:ok, _} = set!(a, "Alice")
    assert {:error, :username_taken} = set!(b, "alice")
    assert {:error, :username_taken} = set!(b, "ALICE")
  end

  @tag :postgres_integration
  test "PER-TENANT: two tenants hold the SAME handle; lookup never crosses" do
    other_app = app!()
    a = user!()
    b = user!(other_app)

    assert {:ok, _} = set!(a, "maria")
    # The same handle in ANOTHER tenant is fine — separate namespaces.
    assert {:ok, _} = set!(b, "maria")

    assert {:ok, %{user_id: ^a}} = lookup("maria", @tenant_zero)
    assert {:ok, %{user_id: ^b}} = lookup("maria", other_app)
  end

  @tag :postgres_integration
  test "@a → @b → @a: reclaim COSTS a change and refunds nothing; the 3rd change is :username_change_limit" do
    u = user!()

    assert {:ok, _} = set!(u, "aaa")
    assert hold_count(u) == 0

    # Change 1: @a → @b (writes hold(@a)).
    assert {:ok, _} = set!(u, "bbb")
    assert hold_count(u) == 1

    # Change 2: reclaim @a (allowed — own hold) — writes hold(@b); hold(@a) STAYS (never deleted).
    assert {:ok, %{username: "aaa"}} = set!(u, "aaa")
    assert hold_count(u) == 2

    # Budget exhausted: the cycle cannot continue.
    assert {:error, :username_change_limit} = set!(u, "bbb")
    assert {:error, :username_change_limit} = set!(u, "ccc")
  end

  @tag :postgres_integration
  test "CASE-ONLY edits are FREE: same key, no hold, no budget — even with the budget exhausted" do
    u = user!()
    assert {:ok, _} = set!(u, "aaa")
    assert {:ok, _} = set!(u, "bbb")
    assert {:ok, _} = set!(u, "aaa")
    assert {:error, :username_change_limit} = set!(u, "ddd")

    # Fixing capitalisation still works, consumes nothing, holds unchanged.
    assert {:ok, %{username: "AAA"}} = set!(u, "AAA")
    assert {:ok, %{username: "AaA"}} = set!(u, "AaA")
    assert hold_count(u) == 2

    # And the identical handle is a free no-op.
    assert {:ok, %{username: "AaA"}} = set!(u, "AaA")
  end

  @tag :postgres_integration
  test "a vacated handle is HELD: a stranger gets :username_held for 30 days; removal writes a hold too" do
    a = user!()
    b = user!()

    assert {:ok, _} = set!(a, "coveted")
    assert {:ok, _} = set!(a, "moved_on")

    # The vacated handle is blocked for OTHERS…
    assert {:error, :username_held} = set!(b, "coveted")
    assert {:error, :username_held} = set!(b, "Coveted")

    # …and after the hold expires (simulate), it frees.
    Repo.query!("UPDATE username_holds SET held_until = now() - interval '1 day' WHERE username_key = 'coveted'", [])
    assert {:ok, _} = set!(b, "coveted")

    # REMOVAL ("" clears) also vacates-with-hold: no instant-release loophole.
    assert {:ok, %{username: nil}} = set!(b, "")
    c = user!()
    assert {:error, :username_held} = set!(c, "coveted")
    assert {:error, :not_found} = lookup("coveted")
  end

  @tag :postgres_integration
  test "ACTIVE-only resolution (the by-phone status filter): suspension goes dark, handle stays blocked" do
    # PARITY NOTE: by-phone's identical `status = 'active'` filter is pinned by its OWN named test
    # (AuthService.AccountsPhoneLookupTest) — a literal same-run cross-module assert is impossible here
    # (user_service has no compile dep on auth_service; adapters resolve at runtime). Both suites pin the
    # same semantic: a non-active account is invisible to discovery. Drift breaks one of the two by name.
    u = user!()
    assert {:ok, _} = set!(u, "ghost")
    assert {:ok, %{user_id: ^u}} = lookup("ghost")

    Repo.query!("UPDATE users_auth SET status = 'suspended' WHERE id = $1::text::uuid", [u])

    # The handle goes dark for discovery (SAME behavior by-phone shows for this exact user)…
    assert {:error, :not_found} = lookup("ghost")

    # …but stays BLOCKED while suspended (the profile row persists) — nobody can take it over.
    other = user!()
    assert {:error, :username_taken} = set!(other, "ghost")

    # Reactivation resolves again — nothing was released.
    Repo.query!("UPDATE users_auth SET status = 'active' WHERE id = $1::text::uuid", [u])
    assert {:ok, %{user_id: ^u}} = lookup("ghost")
  end

  @tag :postgres_integration
  test "availability: taken / held / invalid-with-code / own handle reports available" do
    a = user!()
    b = user!()
    assert {:ok, _} = set!(a, "Popular")

    check = fn user, name ->
      {:ok, result} =
        Usernames.check_availability(%{
          "username" => name,
          "app_id" => @tenant_zero,
          "user_id" => user
        })

      result
    end

    assert %{available: false, code: "username_taken"} = check.(b, "popular")
    # A case-only variant of YOUR OWN handle is not a collision.
    assert %{available: true} = check.(a, "POPULAR")
    assert %{available: false, code: "username_reserved"} = check.(b, "admin")
    assert %{available: false, code: "username_too_short"} = check.(b, "ab")
    assert %{available: true, code: nil} = check.(b, "fresh_name")

    # A held handle reports held for strangers.
    assert {:ok, _} = set!(a, "elsewhere")
    assert %{available: false, code: "username_held"} = check.(b, "popular")
    assert %{available: true} = check.(a, "popular")
  end

  @tag :postgres_integration
  test "username lookup is UNAFFECTED by discoverable_by_phone (the boundary the usernames slice set)" do
    u = user!()
    assert {:ok, _} = set!(u, "findable")

    # Opt fully OUT of phone discovery…
    Repo.query!(
      "INSERT INTO user_privacy_settings (user_id, last_seen_visibility, profile_photo_visibility, " <>
        "read_receipts_enabled, discoverable_by_phone, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, 'contacts', 'contacts', true, false, now(), now())",
      [u]
    )

    # …the HANDLE still resolves: setting a username IS the discovery consent, and removing the handle
    # is its revocation. discoverable_by_phone is phone-only, deliberately.
    assert {:ok, %{user_id: ^u}} = lookup("findable")

    %{rows: [[phone]]} =
      Repo.query!("SELECT phone_number FROM users_auth WHERE id = $1::text::uuid", [u])

    # …while the PHONE path for the same user goes dark.
    assert {:error, :not_found} = AuthService.Accounts.lookup_active_by_phone(phone, @tenant_zero)
  end
end
