defmodule AuthService.DeviceKeysTest do
  @moduledoc """
  The device public-key registry (107) on real SQL: upload binds to (user, device) and ROTATES in
  place; 32-byte validation at the boundary; and the fetch's STORE-LEVEL membership gate — self and
  shared-conversation peers answer, strangers are SILENTLY OMITTED (no existence oracle —
  mutation-proven by stripping the shared-conversation EXISTS), revoked devices and foreign apps
  disappear.
  """
  use AuthService.DataCase, async: false

  alias AuthService.DeviceKeys

  @tenant_zero "00000000-0000-0000-0000-000000000001"

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, email, password_hash, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', 'active', now(), now())",
      [id, @tenant_zero, "keys-#{id}@test.local"]
    )

    id
  end

  defp device!(user_id, device_id, opts \\ []) do
    Repo.query!(
      "INSERT INTO device_sessions " <>
        "(id, user_id, device_id, device_name, platform, refresh_token_hash, revoked_at, created_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'D', $4, 'h', $5, now())",
      [
        Ecto.UUID.generate(),
        user_id,
        device_id,
        Keyword.get(opts, :platform, "android"),
        Keyword.get(opts, :revoked_at)
      ]
    )
  end

  defp key64(byte), do: Base.encode64(:binary.copy(<<byte>>, 32))

  defp save!(user_id, device_id, opts \\ []) do
    DeviceKeys.save_keys(%{
      "user_id" => user_id,
      "device_id" => device_id,
      "app_id" => Keyword.get(opts, :app_id, @tenant_zero),
      "ed25519_public" => Keyword.get(opts, :ed, key64(1)),
      "x25519_public" => Keyword.get(opts, :x, key64(2))
    })
  end

  defp share_conversation!(a, b) do
    conversation = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'group', $3::text::uuid, 'active', now(), now())",
      [conversation, @tenant_zero, a]
    )

    for member <- [a, b] do
      Repo.query!(
        "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, 'member', now())",
        [conversation, member]
      )
    end

    conversation
  end

  defp fetch!(caller, ids) do
    {:ok, %{users: users}} =
      DeviceKeys.fetch_keys(%{"user_id" => caller, "app_id" => @tenant_zero, "ids" => ids})

    users
  end

  @tag :postgres_integration
  test "UPLOAD binds to (user, device) and rotates in place; 32-byte validation" do
    me = user!()
    device!(me, "phone-1")

    # First upload IS a change (108: drives the secret-chat keys_changed system message)…
    assert {:ok, %{saved: true, changed: true}} = save!(me, "phone-1")

    # …an identical re-upload is NOT (no keys_changed spam)…
    assert {:ok, %{changed: false}} = save!(me, "phone-1")

    # …and a rotation replaces the keys under the SAME row and IS a change.
    assert {:ok, %{changed: true}} = save!(me, "phone-1", ed: key64(9), x: key64(8))

    %{rows: [[count, ed]]} =
      Repo.query!(
        "SELECT count(*)::int, max(encode(ed25519_public, 'base64')) FROM device_keys " <>
          "WHERE user_id = $1::text::uuid",
        [me]
      )

    assert count == 1
    assert ed == key64(9)

    # 31 bytes, 33 bytes, and garbage all refuse.
    assert {:error, :device_keys_invalid} =
             save!(me, "phone-1", ed: Base.encode64(:binary.copy(<<1>>, 31)))

    assert {:error, :device_keys_invalid} =
             save!(me, "phone-1", x: Base.encode64(:binary.copy(<<1>>, 33)))

    assert {:error, :device_keys_invalid} = save!(me, "phone-1", ed: "not-base64!!")
  end

  @tag :postgres_integration
  test "FETCH: self + shared-conversation peers; strangers/revoked/foreign silently omitted" do
    me = user!()
    peer = user!()
    stranger = user!()

    device!(me, "my-phone")
    device!(peer, "peer-phone")
    device!(peer, "peer-laptop", platform: "web")
    device!(peer, "peer-dead", revoked_at: ~U[2026-08-01 00:00:00Z])
    device!(stranger, "stranger-phone")

    {:ok, _} = save!(me, "my-phone")
    {:ok, _} = save!(peer, "peer-phone", ed: key64(3), x: key64(4))
    {:ok, _} = save!(peer, "peer-laptop", ed: key64(5), x: key64(6))
    {:ok, _} = save!(peer, "peer-dead")
    {:ok, _} = save!(stranger, "stranger-phone")

    share_conversation!(me, peer)

    users = fetch!(me, [me, peer, stranger])
    by_id = Map.new(users, &{&1.user_id, &1})

    # Self (own other devices) and the shared-conversation peer answer…
    assert Map.has_key?(by_id, me)
    assert %{devices: peer_devices} = by_id[peer]

    # …the peer's REVOKED device is gone; live ones carry platform + both keys, base64.
    assert Enum.map(peer_devices, & &1.device_id) |> Enum.sort() == ["peer-laptop", "peer-phone"]
    phone = Enum.find(peer_devices, &(&1.device_id == "peer-phone"))
    assert phone.platform == "android"
    assert phone.ed25519_public == key64(3)
    assert phone.x25519_public == key64(4)
    # Safety-number fingerprint (108): sha256 of the SIGNING key, hex.
    assert phone.key_fingerprint ==
             Base.encode16(:crypto.hash(:sha256, :binary.copy(<<3>>, 32)), case: :lower)

    # THE GATE: the stranger is SILENTLY OMITTED — absent, not an error (no existence oracle).
    refute Map.has_key?(by_id, stranger)
  end

  @tag :postgres_integration
  test "a departed member no longer resolves the peer (left_at closes the gate)" do
    me = user!()
    peer = user!()
    device!(peer, "peer-phone")
    {:ok, _} = save!(peer, "peer-phone")

    conversation = share_conversation!(me, peer)

    assert [%{user_id: fetched}] = fetch!(me, [peer])
    assert fetched == peer

    Repo.query!(
      "UPDATE conversation_participants SET left_at = now() " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [conversation, me]
    )

    assert fetch!(me, [peer]) == []
  end
end
