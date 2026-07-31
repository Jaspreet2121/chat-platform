defmodule RealtimeGateway.SessionRevocationTest do
  @moduledoc """
  Realtime session revocation (the linked-devices follow-up). Proves: the socket id is per-(user,
  DEVICE) — so the revoke-time `Endpoint.broadcast(id, "disconnect", %{})` severs exactly one device
  while the same user's other devices (different id) are untouched; and THE HEARTBEAT FALLBACK — a
  socket that MISSED the disconnect signal is still severed by the every-10th-beat session re-check
  (≈5 min), which also catches admin suspend/ban (session_active? checks the user's status too). The
  re-check fails OPEN on auth unavailability and skips non-device sockets (/v1 "end_user", the dev
  placeholder). The gateway-side broadcasts at revoke time are ApiGatewayWeb.DeviceControllerTest /
  AuthControllerTest; the session_active? SQL is AuthService.DevicesTest.
  """
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  alias RealtimeGateway.{UserChannel, UserSocket}

  @endpoint RealtimeGateway.TestEndpoint

  defmodule RevokedStub do
    def session_active?(_attrs), do: {:ok, %{active: false}}
  end

  defmodule ActiveStub do
    def session_active?(_attrs), do: {:ok, %{active: true}}
  end

  defmodule DownStub do
    def session_active?(_attrs), do: {:error, :auth_unavailable}
  end

  setup do
    prev_auth = Application.get_env(:shared_infra, :auth_client_adapter)
    prev_socket_auth = Application.get_env(:realtime_gateway, :socket_auth_persistence, false)

    on_exit(fn ->
      if prev_auth,
        do: Application.put_env(:shared_infra, :auth_client_adapter, prev_auth),
        else: Application.delete_env(:shared_infra, :auth_client_adapter)

      Application.put_env(:realtime_gateway, :socket_auth_persistence, prev_socket_auth)
    end)

    :ok
  end

  test "the socket id is per-(user, DEVICE): one device's disconnect topic never matches another's" do
    phone = %Phoenix.Socket{assigns: %{current_user_id: "u1", device_id: "phone-1"}}
    laptop = %Phoenix.Socket{assigns: %{current_user_id: "u1", device_id: "web-aaaa"}}

    assert UserSocket.id(phone) == "user_socket:u1:phone-1"
    assert UserSocket.id(laptop) == "user_socket:u1:web-aaaa"
    # Revoking phone-1 broadcasts to ITS id only — the laptop's id differs, so it is untouched.
    refute UserSocket.id(phone) == UserSocket.id(laptop)
  end

  defp join_device!(device_id) do
    {:ok, _reply, socket} =
      %Phoenix.Socket{}
      |> socket("user_socket:u1:#{device_id}", %{
        current_user_id: "u1",
        user_id: "u1",
        device_id: device_id
      })
      |> subscribe_and_join(UserChannel, "user:u1", %{})

    socket
  end

  defp beat!(socket, times) do
    for _ <- 1..times, do: send(socket.channel_pid, :conn_heartbeat)
    socket
  end

  test "HEARTBEAT FALLBACK: a revoked session that missed the signal is severed on the 10th beat" do
    Application.put_env(:realtime_gateway, :socket_auth_persistence, true)
    Application.put_env(:shared_infra, :auth_client_adapter, RevokedStub)

    socket = join_device!("phone-1")
    @endpoint.subscribe("user_socket:u1:phone-1")

    # Beats 1..9: no re-check yet, the socket lives.
    beat!(socket, 9)
    refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 100

    # The 10th beat re-checks, finds the session dead, and severs THE WHOLE SOCKET by its id.
    beat!(socket, 1)

    assert_receive %Phoenix.Socket.Broadcast{
                     topic: "user_socket:u1:phone-1",
                     event: "disconnect"
                   },
                   500
  end

  test "an ACTIVE session sails through the re-check; auth being DOWN fails OPEN (no fleet-wide sever)" do
    Application.put_env(:realtime_gateway, :socket_auth_persistence, true)

    Application.put_env(:shared_infra, :auth_client_adapter, ActiveStub)
    socket = join_device!("phone-2")
    @endpoint.subscribe("user_socket:u1:phone-2")
    beat!(socket, 10)
    refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 200

    Application.put_env(:shared_infra, :auth_client_adapter, DownStub)
    beat!(socket, 10)
    refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 200
  end

  test "non-device sockets are never re-checked: the /v1 'end_user' pseudo-device survives a false oracle" do
    Application.put_env(:realtime_gateway, :socket_auth_persistence, true)

    # The oracle says false for EVERYTHING — but an end_user socket isn't a device session at all.
    Application.put_env(:shared_infra, :auth_client_adapter, RevokedStub)

    socket = join_device!("end_user")
    @endpoint.subscribe("user_socket:u1:end_user")
    beat!(socket, 10)
    refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 200
  end
end
