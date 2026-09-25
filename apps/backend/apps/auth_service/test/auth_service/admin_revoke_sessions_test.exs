defmodule AuthService.AdminRevokeSessionsTest do
  @moduledoc """
  The moderator's "sign this account out everywhere" (`Devices.revoke_all_sessions/1`).

  Distinct from `revoke_other_devices/1`, which spares the CALLER's device: here the actor is an
  admin, not the account holder, so nothing is spared. It must take the refresh tokens and the push
  tokens with it — an account that is signed out but still receiving pushes is not signed out — and
  it must leave OTHER accounts alone.
  """
  use AuthService.DataCase, async: false

  alias AuthService.Devices

  @tenant "00000000-0000-0000-0000-000000000001"

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, status) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'active')",
      [id, @tenant, "+1555#{System.unique_integer([:positive])}"]
    )

    id
  end

  defp session!(user_id, device_id) do
    Repo.query!(
      "INSERT INTO device_sessions (user_id, device_id, platform, refresh_token_hash) " <>
        "VALUES ($1::text::uuid, $2, 'android', $3)",
      [user_id, device_id, "hash-#{System.unique_integer([:positive])}"]
    )

    Repo.query!(
      "INSERT INTO refresh_tokens (user_id, device_id, token_hash, expires_at) " <>
        "VALUES ($1::text::uuid, $2, $3, now() + interval '30 days')",
      [user_id, device_id, "rt-#{System.unique_integer([:positive])}"]
    )

    Repo.query!(
      "INSERT INTO fcm_tokens (user_id, token, device_id, platform) " <>
        "VALUES ($1::text::uuid, $2, $3, 'android')",
      [user_id, "fcm-#{System.unique_integer([:positive])}", device_id]
    )
  end

  defp live_sessions(user_id) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM device_sessions WHERE user_id = $1::text::uuid AND revoked_at IS NULL",
        [user_id]
      )

    n
  end

  defp live_refresh(user_id) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM refresh_tokens WHERE user_id = $1::text::uuid AND revoked_at IS NULL",
        [user_id]
      )

    n
  end

  defp push_rows(user_id) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM fcm_tokens WHERE user_id = $1::text::uuid", [user_id])

    n
  end

  @tag :postgres_integration
  test "revokes EVERY session, its refresh tokens and its push tokens — and names the devices" do
    user = user!()
    bystander = user!()
    session!(user, "phone-1")
    session!(user, "web-1")
    session!(bystander, "other-1")

    assert live_sessions(user) == 2

    assert {:ok, result} = Devices.revoke_all_sessions(%{"user_id" => user})

    assert result.revoked_count == 2
    assert Enum.sort(result.revoked_device_ids) == ["phone-1", "web-1"]

    # Nothing live is left, on any of the three tables.
    assert live_sessions(user) == 0
    assert live_refresh(user) == 0
    assert push_rows(user) == 0

    # ...and the bystander is untouched. An admin action on one account must not reach another.
    assert live_sessions(bystander) == 1
    assert push_rows(bystander) == 1
  end

  @tag :postgres_integration
  test "is idempotent: a second call answers 0, not an error (an operator may press twice)" do
    user = user!()
    session!(user, "phone-1")

    assert {:ok, %{revoked_count: 1}} = Devices.revoke_all_sessions(%{"user_id" => user})

    assert {:ok, %{revoked_count: 0, revoked_device_ids: []}} =
             Devices.revoke_all_sessions(%{"user_id" => user})
  end

  @tag :postgres_integration
  test "unlike revoke_other_devices, it spares NOTHING — the admin is not the account holder" do
    user = user!()
    session!(user, "phone-1")
    session!(user, "web-1")

    # The user-driven call keeps the named device alive...
    assert {:ok, %{revoked_count: 1}} =
             Devices.revoke_other_devices(%{"user_id" => user, "device_id" => "phone-1"})

    assert live_sessions(user) == 1

    # ...the admin call does not.
    assert {:ok, %{revoked_count: 1}} = Devices.revoke_all_sessions(%{"user_id" => user})
    assert live_sessions(user) == 0
  end
end
