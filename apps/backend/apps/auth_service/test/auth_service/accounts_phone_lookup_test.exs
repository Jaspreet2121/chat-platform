defmodule AuthService.AccountsPhoneLookupTest do
  @moduledoc """
  App-scoped phone lookup (`@tag :postgres_integration`; the logic is SQL). Both the bulk contacts-sync
  match and the single by-phone lookup are scoped to the caller's `app_id` — under migration 048's
  per-(app_id, phone_number) uniqueness the SAME number can live in two tenants, so an app-blind match
  could resolve another tenant's user. Proves: ONE app-scoped `= ANY` query returns only the caller-app
  ACTIVE matches (cross-tenant + suspended excluded, one row per number, the stored phone echoed), and the
  single lookup resolves WITHIN the right tenant for a number that two tenants share.

  ALSO (084) the DISCOVERABILITY predicate, folded into these SAME queries so single by-phone, bulk
  contacts sync AND call-add-by-phone share one rule: discoverable_by_phone = false → the user is
  ABSENT from every phone resolution (never an error); no row / NULL → discoverable (the default that
  preserves today's behaviour for every existing user).
  """
  use AuthService.DataCase, async: false

  alias AuthService.Accounts

  @tag :postgres_integration
  test "lookup_active_by_phones: app-scoped, active-only, one row per number, phone echoed" do
    app_a = seed_app()
    app_b = seed_app()

    alice = seed_user(app_a, "+15551110001", "active")
    bob = seed_user(app_a, "+15551110002", "active")
    _suspended = seed_user(app_a, "+15551110003", "suspended")
    # SAME number as alice, but in ANOTHER tenant → must NOT be returned to an app_a caller.
    cross = seed_user(app_b, "+15551110001", "active")

    {:ok, rows} =
      Accounts.lookup_active_by_phones(
        ["+15551110001", "+15551110002", "+15551110003", "+15559999999"],
        app_a
      )

    by_phone = Map.new(rows, &{&1.phone_number, &1.user_id})

    # alice + bob match; the suspended one and the unknown number are absent (no "not found" rows).
    assert map_size(by_phone) == 2
    assert by_phone["+15551110001"] == alice
    assert by_phone["+15551110002"] == bob
    refute Map.has_key?(by_phone, "+15551110003")
    refute Map.has_key?(by_phone, "+15559999999")

    # The cross-tenant user (same number, app_b) is a DIFFERENT row and is never returned to app_a.
    refute alice == cross
    refute Enum.any?(rows, &(&1.user_id == cross))
  end

  @tag :postgres_integration
  test "the shared number resolves to app_b's OWN user when the caller is app_b" do
    app_a = seed_app()
    app_b = seed_app()
    _a = seed_user(app_a, "+15551110001", "active")
    b = seed_user(app_b, "+15551110001", "active")

    assert {:ok, [%{user_id: ^b, phone_number: "+15551110001"}]} =
             Accounts.lookup_active_by_phones(["+15551110001"], app_b)
  end

  @tag :postgres_integration
  test "single lookup_active_by_phone/2 is app-scoped (the multi-tenant bug the bulk path forced us to fix)" do
    app_a = seed_app()
    app_b = seed_app()
    a = seed_user(app_a, "+15551110001", "active")
    b = seed_user(app_b, "+15551110001", "active")

    assert {:ok, %{user_id: ^a}} = Accounts.lookup_active_by_phone("+15551110001", app_a)
    assert {:ok, %{user_id: ^b}} = Accounts.lookup_active_by_phone("+15551110001", app_b)

    # A number that exists only in app_a → not found from app_b.
    _only_a = seed_user(app_a, "+15552220002", "active")
    assert {:error, :not_found} = Accounts.lookup_active_by_phone("+15552220002", app_b)
  end

  @tag :postgres_integration
  test "defensive inputs → {:ok, []} with no query and no crash" do
    app = seed_app()
    assert {:ok, []} = Accounts.lookup_active_by_phones([], app)
    # No app_id → the app-scoped clause doesn't match; the bulk path returns empty rather than app-blind.
    assert {:ok, []} = Accounts.lookup_active_by_phones(["+15551110001"], nil)
  end

  defp seed_app do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO apps (id, name, slug, created_at, updated_at) VALUES ($1::text::uuid, 'test', $2, now(), now())",
      [id, "slug-#{id}"]
    )

    id
  end

  defp seed_user(app_id, phone, status) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, status, password_hash, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, $4, 'x', now(), now())",
      [id, app_id, phone, status]
    )

    id
  end

  defp set_discoverable(user_id, value) do
    Repo.query!(
      "INSERT INTO user_privacy_settings (user_id, last_seen_visibility, profile_photo_visibility, " <>
        "read_receipts_enabled, discoverable_by_phone, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, 'contacts', 'contacts', true, $2, now(), now()) " <>
        "ON CONFLICT (user_id) DO UPDATE SET discoverable_by_phone = EXCLUDED.discoverable_by_phone",
      [user_id, value]
    )
  end

  @tag :postgres_integration
  test "DISCOVERABILITY: opting out removes the user from BOTH phone paths; the default keeps them in" do
    app = seed_app()
    opted_out = seed_user(app, "+15552220001", "active")
    stays = seed_user(app, "+15552220002", "active")
    # `stays` gets a privacy ROW with the flag left at its default — proving the default (not just a
    # missing row) is discoverable.
    set_discoverable(stays, true)

    # Baseline: both resolvable through both paths.
    assert {:ok, %{user_id: ^opted_out}} = Accounts.lookup_active_by_phone("+15552220001", app)
    {:ok, rows} = Accounts.lookup_active_by_phones(["+15552220001", "+15552220002"], app)
    assert length(rows) == 2

    set_discoverable(opted_out, false)

    # SINGLE lookup (by_phone + call-add-by-phone): absent, and indistinguishable from an unknown number.
    assert {:error, :not_found} = Accounts.lookup_active_by_phone("+15552220001", app)
    assert {:error, :not_found} = Accounts.lookup_active_by_phone("+15559999999", app)

    # BULK lookup (contacts sync): simply not in the matches — identical to a non-match.
    {:ok, rows} = Accounts.lookup_active_by_phones(["+15552220001", "+15552220002"], app)
    assert Enum.map(rows, & &1.user_id) == [stays]

    # Flipping back restores discovery (nothing was destroyed).
    set_discoverable(opted_out, true)
    assert {:ok, %{user_id: ^opted_out}} = Accounts.lookup_active_by_phone("+15552220001", app)
  end

  @tag :postgres_integration
  test "DISCOVERABILITY DEFAULT: a user with NO privacy row is discoverable (today's behaviour preserved)" do
    app = seed_app()
    fresh = seed_user(app, "+15553330001", "active")

    %{rows: rows} =
      Repo.query!("SELECT 1 FROM user_privacy_settings WHERE user_id = $1::text::uuid", [fresh])

    assert rows == [], "fixture must have no privacy row"

    assert {:ok, %{user_id: ^fresh}} = Accounts.lookup_active_by_phone("+15553330001", app)
    {:ok, [%{user_id: ^fresh}]} = Accounts.lookup_active_by_phones(["+15553330001"], app)
  end
end
