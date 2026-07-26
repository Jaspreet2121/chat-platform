defmodule UserService.PrivacyTest do
  @moduledoc """
  UserService.Privacy — the real read/write over `user_privacy_settings` (`@tag :postgres_integration`; the
  logic is DB). get_privacy defaults for a user with no row; update_privacy is SPARSE (untouched keys keep
  their stored value / default) and enum-validated; empty → :privacy_empty. Explicitly covers
  read_receipts_enabled = FALSE (the `||`-vs-`has_key?` trap).
  """
  use UserService.DataCase, async: false

  alias UserService.Privacy

  setup do
    prev = Application.get_env(:user_service, :user_profile_persistence, false)
    Application.put_env(:user_service, :user_profile_persistence, true)
    on_exit(fn -> Application.put_env(:user_service, :user_profile_persistence, prev) end)
    :ok
  end

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, email, password_hash, created_at, updated_at) VALUES ($1::text::uuid, $2, 'x', now(), now())",
      [id, "#{id}@test.local"]
    )

    id
  end

  @tag :postgres_integration
  test "get_privacy returns the DEFAULTS for a user with no settings row" do
    u = user!()

    assert {:ok,
            %{
              last_seen_visibility: "contacts",
              profile_photo_visibility: "contacts",
              read_receipts_enabled: true
            }} = Privacy.get_privacy(%{"user_id" => u})
  end

  @tag :postgres_integration
  test "first update CREATES a row (defaults for untouched keys); later updates are SPARSE" do
    u = user!()

    assert {:ok, p1} = Privacy.update_privacy(%{"user_id" => u, "last_seen_visibility" => "everyone"})
    assert p1.last_seen_visibility == "everyone"
    assert p1.profile_photo_visibility == "contacts"
    assert p1.read_receipts_enabled == true

    # A sparse update touching ONLY read_receipts_enabled must not reset last_seen_visibility.
    assert {:ok, p2} = Privacy.update_privacy(%{"user_id" => u, "read_receipts_enabled" => false})
    assert p2.read_receipts_enabled == false
    assert p2.last_seen_visibility == "everyone"

    assert {:ok, %{last_seen_visibility: "everyone", read_receipts_enabled: false}} =
             Privacy.get_privacy(%{"user_id" => u})
  end

  @tag :postgres_integration
  test "read_receipts_enabled = FALSE round-trips (the || trap)" do
    u = user!()
    assert {:ok, %{read_receipts_enabled: false}} =
             Privacy.update_privacy(%{"user_id" => u, "read_receipts_enabled" => false})

    assert {:ok, %{read_receipts_enabled: false}} = Privacy.get_privacy(%{"user_id" => u})
  end

  @tag :postgres_integration
  test "an invalid enum → :privacy_invalid_value, and nothing is written" do
    u = user!()

    assert {:error, :privacy_invalid_value} =
             Privacy.update_privacy(%{"user_id" => u, "last_seen_visibility" => "mars"})

    assert {:ok, %{last_seen_visibility: "contacts"}} = Privacy.get_privacy(%{"user_id" => u})
  end

  @tag :postgres_integration
  test "a non-boolean read_receipts_enabled → :privacy_invalid_value" do
    u = user!()

    assert {:error, :privacy_invalid_value} =
             Privacy.update_privacy(%{"user_id" => u, "read_receipts_enabled" => "maybe"})
  end

  @tag :postgres_integration
  test "an empty / unrecognised-only body → :privacy_empty (never a no-op write)" do
    u = user!()
    assert {:error, :privacy_empty} = Privacy.update_privacy(%{"user_id" => u})
    assert {:error, :privacy_empty} = Privacy.update_privacy(%{"user_id" => u, "nope" => "x"})
  end
end
