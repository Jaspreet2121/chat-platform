defmodule ApiGatewayWeb.DeviceControllerTest do
  @moduledoc """
  Linked-devices endpoints (Docker-free; AuthClient stubbed). Proves the contract: the list marks
  `current` by comparing rows against the SESSION's device_id; DELETE of the CURRENT device → 400
  devices.cannot_revoke_current WITHOUT the revoke op ever being called (logout owns that gesture);
  DELETE of another device → 200 {revoked}; foreign/unknown → 404 devices.not_found; revoke-others →
  200 {revoked_count}; no session → 401. The SQL (ordering, sweep, FCM deletion, immediacy) is proven
  in AuthService.DevicesTest.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ApiGatewayWeb.DeviceController

  @me "11111111-1111-4111-8111-111111111111"
  @current_device "web-aaaa"

  defmodule AuthStub do
    @me "11111111-1111-4111-8111-111111111111"

    def current_session(%{"authorization" => "Bearer me"}),
      do: {:ok, %{user_id: @me, device_id: "web-aaaa", app_id: "app1"}}

    def current_session(_), do: {:error, :session_invalid}

    def list_devices(%{"user_id" => @me}) do
      {:ok,
       %{
         devices: [
           %{device_id: "phone-1", device_name: "Pixel 9", platform: "android", last_seen_at: "t2", created_at: "t0"},
           %{device_id: "web-aaaa", device_name: "Chrome on macOS", platform: "web", last_seen_at: "t1", created_at: "t0"}
         ]
       }}
    end

    def revoke_device(%{"device_id" => "phone-1"} = attrs) do
      send(:device_controller_test, {:revoked, attrs})
      {:ok, %{revoked: true}}
    end

    def revoke_device(_attrs), do: {:error, :device_not_found}

    def revoke_other_devices(%{"user_id" => @me, "device_id" => "web-aaaa"}),
      do: {:ok, %{revoked_count: 2, revoked_device_ids: ["phone-1", "tablet-2"]}}
  end

  setup do
    Process.register(self(), :device_controller_test)
    prev = Application.get_env(:shared_infra, :auth_client_adapter)
    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:shared_infra, :auth_client_adapter, prev),
        else: Application.delete_env(:shared_infra, :auth_client_adapter)
    end)

    :ok
  end

  defp authed(method, token \\ "me") do
    method |> conn("/x", %{}) |> put_req_header("authorization", "Bearer #{token}")
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  test "GET list: rows pass through with `current` derived from the session's device_id" do
    conn = DeviceController.index(authed(:get), %{})
    assert conn.status == 200

    assert [phone, web] = body(conn)["devices"]
    assert phone["device_id"] == "phone-1"
    assert phone["current"] == false
    assert phone["device_name"] == "Pixel 9"
    assert web["device_id"] == @current_device
    assert web["current"] == true
  end

  test "DELETE another device → 200 {revoked: true} (the op runs, caller-scoped)" do
    conn = DeviceController.delete(authed(:delete), %{"device_id" => "phone-1"})
    assert conn.status == 200
    assert body(conn) == %{"revoked" => true}
    assert_received {:revoked, %{"user_id" => @me, "device_id" => "phone-1"}}
  end

  test "DELETE the CURRENT device → 400 devices.cannot_revoke_current, and the revoke op is NEVER called" do
    conn = DeviceController.delete(authed(:delete), %{"device_id" => @current_device})
    assert conn.status == 400
    assert body(conn)["error"]["code"] == "devices.cannot_revoke_current"
    refute_received {:revoked, _}
  end

  test "foreign / unknown device_id → 404 devices.not_found (no existence reveal)" do
    conn = DeviceController.delete(authed(:delete), %{"device_id" => "someone-elses"})
    assert conn.status == 404
    assert body(conn)["error"]["code"] == "devices.not_found"
  end

  test "POST revoke-others → 200 {revoked_count}" do
    conn = DeviceController.revoke_others(authed(:post), %{})
    assert conn.status == 200
    assert body(conn) == %{"revoked_count" => 2}
  end

  test "no session → 401 on all three" do
    assert DeviceController.index(authed(:get, "nobody"), %{}).status == 401
    assert DeviceController.delete(authed(:delete, "nobody"), %{"device_id" => "x"}).status == 401
    assert DeviceController.revoke_others(authed(:post, "nobody"), %{}).status == 401
  end

  test "REVOKE severs exactly that device's live socket; the caller's own socket is untouched" do
    # The per-(user, device) socket id is what makes this surgical.
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user_socket:#{@me}:phone-1")
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user_socket:#{@me}:#{@current_device}")

    conn = DeviceController.delete(authed(:delete), %{"device_id" => "phone-1"})
    assert conn.status == 200

    assert_receive %Phoenix.Socket.Broadcast{
                     topic: "user_socket:" <> _,
                     event: "disconnect"
                   },
                   1000

    # The CALLER's own device keeps its socket (nothing else was severed).
    refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 200
  end

  test "REVOKE-OTHERS severs each swept device, and only those" do
    for device <- ["phone-1", "tablet-2"],
        do: Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user_socket:#{@me}:#{device}")

    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user_socket:#{@me}:#{@current_device}")

    conn = DeviceController.revoke_others(authed(:post), %{})
    assert conn.status == 200
    assert body(conn) == %{"revoked_count" => 2}

    # One disconnect per swept device…
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 1000
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 1000
    # …and nothing for the current device (it was excluded from the sweep by construction).
    refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 200
  end

  test "a REFUSED self-revoke severs nothing" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user_socket:#{@me}:#{@current_device}")

    conn = DeviceController.delete(authed(:delete), %{"device_id" => @current_device})
    assert conn.status == 400

    refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 200
  end
end
