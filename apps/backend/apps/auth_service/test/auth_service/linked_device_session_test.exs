defmodule AuthService.LinkedDeviceSessionTest do
  @moduledoc """
  The QR-link session mint + the asymmetric revocation rule (099), on real SQL.

  `link_device_session/1`: a fresh platform-web device_session with linked_by_device_id = the
  approving phone, its refresh-token row, and an access token whose claims carry the PHONE's
  app_id (never a default). Revocation: the phone revokes its linked devices; a LINKED session can
  never revoke a PRIMARY (mutation-proven); an unknown caller row fails closed to the weaker
  privilege.
  """
  use AuthService.DataCase, async: false

  alias AuthService.{Devices, Tokens}

  @app "44444444-4444-4444-8444-444444444444"

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, email, password_hash, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2, 'x', now(), now())",
      [id, "u-#{id}@test.local"]
    )

    id
  end

  defp device!(user_id, device_id, opts \\ []) do
    Repo.query!(
      "INSERT INTO device_sessions " <>
        "(id, user_id, device_id, device_name, platform, refresh_token_hash, linked_by_device_id, created_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, $4, $5, $6, $7, now())",
      [
        Ecto.UUID.generate(),
        user_id,
        device_id,
        opts[:name],
        opts[:platform] || "web",
        "hash-#{device_id}",
        opts[:linked_by]
      ]
    )

    device_id
  end

  @tag :postgres_integration
  test "link_device_session mints the web session: row + refresh + app-stamped claims" do
    user = user!()

    assert {:ok, minted} =
             Devices.link_device_session(%{
               "user_id" => user,
               "app_id" => @app,
               "device_name" => "Chrome on Mac",
               "linked_by_device_id" => "phone-1"
             })

    assert is_binary(minted.access_token)
    assert is_binary(minted.refresh_token)
    assert String.starts_with?(minted.device_id, "web-")
    assert minted.device_name == "Chrome on Mac"

    # The device_session row: platform web, provenance recorded.
    %{rows: [[platform, linked_by, revoked_at]]} =
      Repo.query!(
        "SELECT platform, linked_by_device_id, revoked_at FROM device_sessions " <>
          "WHERE user_id = $1::text::uuid AND device_id = $2",
        [user, minted.device_id]
      )

    assert platform == "web"
    assert linked_by == "phone-1"
    assert is_nil(revoked_at)

    # Its refresh token exists…
    %{rows: [[refresh_count]]} =
      Repo.query!(
        "SELECT count(*)::int FROM refresh_tokens WHERE user_id = $1::text::uuid AND device_id = $2",
        [user, minted.device_id]
      )

    assert refresh_count == 1

    # …and the ACCESS token's claims are the linked session's identity, tenant included — the
    # PHONE's app, never tenant-zero-by-default.
    assert {:ok, claims} = Tokens.verify_signed_token(minted.access_token)
    assert claims["sub"] == user
    assert claims["did"] == minted.device_id
    assert claims["sid"] == minted.session_id
    assert claims["app"] == @app

    # The linked-devices list carries the provenance for the client.
    assert {:ok, %{devices: devices}} = Devices.list_devices(%{"user_id" => user})
    row = Enum.find(devices, &(&1.device_id == minted.device_id))
    assert row.linked_by == "phone-1"
  end

  @tag :postgres_integration
  test "ASYMMETRY: phone revokes linked OK; a linked session can NEVER revoke a primary" do
    user = user!()
    phone = device!(user, "phone-1", platform: "android")
    web = device!(user, "web-aaaa", linked_by: "phone-1")

    # The linked browser must not sign the phone out.
    assert {:error, :cannot_revoke_primary} =
             Devices.revoke_device(%{
               "user_id" => user,
               "device_id" => phone,
               "caller_device_id" => web
             })

    # The phone revokes its linked browser.
    assert {:ok, %{revoked: true}} =
             Devices.revoke_device(%{
               "user_id" => user,
               "device_id" => web,
               "caller_device_id" => phone
             })

    # An UNKNOWN caller device row fails closed to the linked (weaker) privilege.
    assert {:error, :cannot_revoke_primary} =
             Devices.revoke_device(%{
               "user_id" => user,
               "device_id" => phone,
               "caller_device_id" => "ghost-device"
             })
  end

  @tag :postgres_integration
  test "a linked session may revoke ANOTHER linked session (only primaries are protected)" do
    user = user!()
    _phone = device!(user, "phone-1", platform: "android")
    web_a = device!(user, "web-aaaa", linked_by: "phone-1")
    web_b = device!(user, "web-bbbb", linked_by: "phone-1")

    assert {:ok, %{revoked: true}} =
             Devices.revoke_device(%{
               "user_id" => user,
               "device_id" => web_b,
               "caller_device_id" => web_a
             })
  end
end
