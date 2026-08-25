defmodule ApiGatewayWeb.PushControllerTest do
  @moduledoc """
  The subscribe path's half of 103: the gateway stamps the SESSION's device_id onto the saved
  web-push subscription (never a client-supplied value), so device revocation can find and delete
  the browser's subscription. Delete stays endpoint+caller scoped, no device involved.
  """
  use ExUnit.Case, async: false

  import Plug.Test

  alias ApiGatewayWeb.PushController

  defmodule AuthStub do
    @moduledoc false
    def current_session(%{"authorization" => "Bearer me"}) do
      {:ok,
       %{
         user_id: "11111111-1111-1111-1111-111111111111",
         app_id: "44444444-4444-4444-8444-444444444444",
         device_id: "web-cafe1234"
       }}
    end

    def current_session(_), do: {:error, :session_invalid}

    def save_push_subscription(attrs) do
      send(:push_ctl_test, {:saved, attrs})
      {:ok, %{saved: true}}
    end

    def delete_push_subscription(attrs) do
      send(:push_ctl_test, {:deleted, attrs})
      {:ok, %{deleted: true}}
    end
  end

  setup do
    Process.register(self(), :push_ctl_test)
    prev = Application.get_env(:shared_infra, :auth_client_adapter)
    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:shared_infra, :auth_client_adapter, prev),
        else: Application.delete_env(:shared_infra, :auth_client_adapter)
    end)

    :ok
  end

  defp request(action, params) do
    :post
    |> conn("/api/v1/push/subscriptions", params)
    |> Plug.Conn.put_req_header("authorization", "Bearer me")
    |> then(&PushController.call(&1, PushController.init(action)))
  end

  test "subscribe stamps the SESSION's device_id (103) — even if the client sends its own" do
    conn =
      request(:create, %{
        "endpoint" => "https://push.example/ep1",
        "keys" => %{"p256dh" => "k", "auth" => "a"},
        # A client-supplied device_id must be ignored: the linkage is session identity.
        "device_id" => "spoofed-device"
      })

    assert conn.status == 200
    assert_receive {:saved, attrs}
    assert attrs["device_id"] == "web-cafe1234"
    assert attrs["user_id"] == "11111111-1111-1111-1111-111111111111"
    assert attrs["endpoint"] == "https://push.example/ep1"
  end

  test "unsubscribe carries caller + endpoint only" do
    conn = request(:delete, %{"endpoint" => "https://push.example/ep1"})

    assert conn.status == 200
    assert_receive {:deleted, attrs}

    assert attrs == %{
             "user_id" => "11111111-1111-1111-1111-111111111111",
             "endpoint" => "https://push.example/ep1"
           }
  end
end
