defmodule AuthService.LookupExternalUserTest do
  @moduledoc """
  `lookup_external_user/2` — the resolve-ONLY twin of `resolve_or_create_external_user/2`, for read/reference
  contexts. The defect it closes: three LOOKUP call-sites (call callee, GET /v1/presence, presence subscribe)
  used the resolve-or-CREATE variant, so a bogus external id on a GET created an inert user row. The count
  assertions here pin exactly that: a missed lookup creates NOTHING.

  DB-backed → opt-in (:postgres_integration) so the default `mix test` stays Docker-free.
  """
  use AuthService.DataCase, async: false

  @moduletag :postgres_integration

  alias AuthService.Accounts

  @app_id "00000000-0000-0000-0000-000000000001"

  defp user_count do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM users_auth", [])
    n
  end

  test "an existing external user resolves — to the SAME id resolve_or_create would give" do
    ext = "known_#{Ecto.UUID.generate()}"
    {:ok, %{user_id: created_id}} = Accounts.resolve_or_create_external_user(@app_id, ext)

    before = user_count()

    assert {:ok, %{user_id: ^created_id}} = Accounts.lookup_external_user(@app_id, ext)
    # A hit is pure read — nothing created.
    assert user_count() == before
  end

  test "THE DEFECT: an unknown external id → :user_not_found and NO users_auth row is created" do
    before = user_count()

    assert {:error, :user_not_found} =
             Accounts.lookup_external_user(@app_id, "ghost_#{Ecto.UUID.generate()}")

    # The resolve-or-create variant would have inserted a row here.
    assert user_count() == before
  end

  test "scoping matches resolve: the SAME external id in ANOTHER app does not resolve (and creates nothing)" do
    ext = "scoped_#{Ecto.UUID.generate()}"
    {:ok, _} = Accounts.resolve_or_create_external_user(@app_id, ext)

    other_app = Ecto.UUID.generate()
    Repo.query!("INSERT INTO apps (id, name, slug, created_at, updated_at) VALUES ($1::text::uuid, 'other', $2, now(), now())", [other_app, "slug-#{other_app}"])

    before = user_count()
    assert {:error, :user_not_found} = Accounts.lookup_external_user(other_app, ext)
    assert user_count() == before
  end

  test "blank / invalid input → :user_not_found, no crash, no row" do
    before = user_count()
    assert {:error, :user_not_found} = Accounts.lookup_external_user(@app_id, "")
    assert {:error, :user_not_found} = Accounts.lookup_external_user("", "someone")
    assert user_count() == before
  end

  test "PROVISION REGRESSION: resolve_or_create still CREATES on first sight (JIT intact for write contexts)" do
    ext = "fresh_#{Ecto.UUID.generate()}"
    before = user_count()

    assert {:ok, %{user_id: id}} = Accounts.resolve_or_create_external_user(@app_id, ext)
    assert user_count() == before + 1

    # …and the lookup now finds what provisioning created.
    assert {:ok, %{user_id: ^id}} = Accounts.lookup_external_user(@app_id, ext)
  end
end
