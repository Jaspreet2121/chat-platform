defmodule AuthService.DevicesTest do
  @moduledoc """
  Linked devices (`@tag :postgres_integration`). Proves: the list is the CALLER's non-revoked sessions
  only, most-recently-seen first (NULL last_seen_at last); revoke marks the device_session + revokes its
  active refresh tokens + deletes its FCM rows while the caller's OTHER device is untouched;
  foreign / unknown / already-revoked device_ids are :device_not_found (no existence leak);
  revoke-others sweeps everything but the current device; and THE IMMEDIACY GUARANTEE — a still-valid
  access token for a revoked device fails `Sessions.current_session` on the very next call (decision 2:
  no 15-minute grace, because validation already reads the device_session row).
  """
  use AuthService.DataCase, async: false

  alias AuthService.{Devices, Sessions, Tokens}

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
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO device_sessions " <>
        "(id, user_id, device_id, device_name, platform, refresh_token_hash, last_seen_at, revoked_at, created_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, $4, $5, $6, $7, $8, now())",
      [
        id,
        user_id,
        device_id,
        opts[:name],
        opts[:platform] || "web",
        opts[:refresh_hash] || "hash-#{device_id}",
        opts[:last_seen],
        opts[:revoked_at]
      ]
    )

    id
  end

  defp refresh!(user_id, device_id, hash) do
    Repo.query!(
      "INSERT INTO refresh_tokens (id, user_id, device_id, token_hash, expires_at, created_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, $4, now() + interval '30 days', now())",
      [Ecto.UUID.generate(), user_id, device_id, hash]
    )
  end

  defp fcm!(user_id, device_id) do
    Repo.query!(
      "INSERT INTO fcm_tokens (user_id, token, device_id, platform) VALUES ($1::text::uuid, $2, $3, 'android')",
      [user_id, "fcm-#{device_id}-#{Ecto.UUID.generate()}", device_id]
    )
  end

  defp count!(sql, params) do
    %{rows: [[n]]} = Repo.query!(sql, params)
    n
  end

  defp active_refresh_count(user_id, device_id),
    do:
      count!(
        "SELECT count(*)::int FROM refresh_tokens WHERE user_id = $1::text::uuid AND device_id = $2 AND revoked_at IS NULL",
        [user_id, device_id]
      )

  defp fcm_count(user_id, device_id),
    do:
      count!(
        "SELECT count(*)::int FROM fcm_tokens WHERE user_id = $1::text::uuid AND device_id = $2",
        [user_id, device_id]
      )

  defp list!(user_id) do
    {:ok, %{devices: devices}} = Devices.list_devices(%{"user_id" => user_id})
    devices
  end

  @tag :postgres_integration
  test "list: caller's NON-revoked sessions only, most-recently-seen first, NULL last_seen last" do
    me = user!()
    other = user!()

    device!(me, "phone", name: "Pixel", platform: "android", last_seen: ~U[2026-07-30 10:00:00Z])
    device!(me, "laptop", name: "Chrome on macOS", last_seen: ~U[2026-07-30 12:00:00Z])
    device!(me, "old-tab", last_seen: nil)

    device!(me, "revoked-one",
      last_seen: ~U[2026-07-30 13:00:00Z],
      revoked_at: ~U[2026-07-30 13:30:00Z]
    )

    device!(other, "their-phone", last_seen: ~U[2026-07-30 14:00:00Z])

    devices = list!(me)

    # Revoked + foreign rows absent; order = last_seen DESC with NULL last.
    assert Enum.map(devices, & &1.device_id) == ["laptop", "phone", "old-tab"]
    assert Enum.map(devices, & &1.device_name) == ["Chrome on macOS", "Pixel", nil]

    assert %{platform: "android", last_seen_at: "2026-07-30T10:00:00.000000Z"} =
             Enum.at(devices, 1)
  end

  @tag :postgres_integration
  test "revoke: session marked + refresh tokens revoked + FCM rows deleted; the OTHER device untouched" do
    me = user!()
    device!(me, "phone", platform: "android")
    device!(me, "laptop")
    refresh!(me, "phone", "rt-phone")
    refresh!(me, "laptop", "rt-laptop")
    fcm!(me, "phone")
    fcm!(me, "laptop")

    assert {:ok, %{revoked: true}} =
             Devices.revoke_device(%{"user_id" => me, "device_id" => "phone"})

    # The revoked device: gone from the list, refresh dead, FCM gone.
    assert Enum.map(list!(me), & &1.device_id) == ["laptop"]
    assert active_refresh_count(me, "phone") == 0
    assert fcm_count(me, "phone") == 0

    # The surviving device: fully intact.
    assert active_refresh_count(me, "laptop") == 1
    assert fcm_count(me, "laptop") == 1
  end

  @tag :postgres_integration
  test "unknown, FOREIGN, and already-revoked device_ids are all :device_not_found (no existence leak)" do
    me = user!()
    other = user!()
    device!(me, "mine")
    device!(other, "theirs")
    device!(me, "gone", revoked_at: ~U[2026-07-30 09:00:00Z])

    assert {:error, :device_not_found} =
             Devices.revoke_device(%{"user_id" => me, "device_id" => "nope"})

    assert {:error, :device_not_found} =
             Devices.revoke_device(%{"user_id" => me, "device_id" => "theirs"})

    assert {:error, :device_not_found} =
             Devices.revoke_device(%{"user_id" => me, "device_id" => "gone"})

    # The foreign device is untouched.
    assert Enum.map(list!(other), & &1.device_id) == ["theirs"]
  end

  @tag :postgres_integration
  test "revoke-others: sweeps every device EXCEPT the current one" do
    me = user!()
    device!(me, "current", last_seen: ~U[2026-07-30 12:00:00Z])
    device!(me, "phone", platform: "android")
    device!(me, "tablet")
    refresh!(me, "phone", "rt-p")
    fcm!(me, "tablet")

    assert {:ok, %{revoked_count: 2}} =
             Devices.revoke_other_devices(%{"user_id" => me, "device_id" => "current"})

    assert Enum.map(list!(me), & &1.device_id) == ["current"]
    assert active_refresh_count(me, "phone") == 0
    assert fcm_count(me, "tablet") == 0

    # Idempotent second sweep: nothing left to revoke.
    assert {:ok, %{revoked_count: 0}} =
             Devices.revoke_other_devices(%{"user_id" => me, "device_id" => "current"})
  end

  @tag :postgres_integration
  test "IMMEDIACY: a revoked device's still-valid access token fails current_session on the NEXT call" do
    prev = Application.get_env(:auth_service, :session_persistence, false)
    Application.put_env(:auth_service, :session_persistence, true)
    on_exit(fn -> Application.put_env(:auth_service, :session_persistence, prev) end)

    me = user!()
    session_id = Ecto.UUID.generate()

    {:ok, pair} =
      Tokens.prepare_issue_pair(%{
        "user_id" => me,
        "device_id" => "phone",
        "session_id" => session_id
      })

    device!(me, "phone",
      platform: "android",
      refresh_hash: pair.refresh_token_attrs["token_hash"]
    )

    # Make the inserted row's id the token's sid (device! generated its own).
    Repo.query!(
      "UPDATE device_sessions SET id = $1::text::uuid WHERE user_id = $2::text::uuid AND device_id = 'phone'",
      [session_id, me]
    )

    authed = %{"authorization" => "Bearer " <> pair.access_token}

    # The token works…
    assert {:ok, %{user_id: ^me, device_id: "phone"}} = Sessions.current_session(authed)

    # …the device is revoked…
    assert {:ok, _} = Devices.revoke_device(%{"user_id" => me, "device_id" => "phone"})

    # …and the SAME (unexpired) token is rejected immediately — no access-token grace window.
    assert {:error, :session_invalid} = Sessions.current_session(authed)
  end
end
