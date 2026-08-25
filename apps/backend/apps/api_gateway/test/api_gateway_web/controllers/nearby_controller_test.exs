defmodule ApiGatewayWeb.NearbyControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.NearbyController

  @me "11111111-1111-1111-1111-111111111111"
  @peer "22222222-2222-2222-2222-222222222222"
  @app "44444444-4444-4444-8444-444444444444"
  @request "55555555-5555-4555-8555-555555555555"

  defmodule AuthStub do
    def current_session(%{"authorization" => "Bearer token"}),
      do:
        {:ok,
         %{
           user_id: "11111111-1111-1111-1111-111111111111",
           app_id: "44444444-4444-4444-8444-444444444444"
         }}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule UserStub do
    def discover_nearby(attrs) do
      send(:nearby_test_collector, {:discover, attrs})

      {:ok,
       %{
         people: [
           %{
             user_id: "22222222-2222-2222-2222-222222222222",
             distance_bucket_m: 100,
             relationship: "none"
           }
         ],
         expires_in_seconds: 300,
         radius_m: attrs["radius_m"]
       }}
    end

    def stop_nearby(attrs) do
      send(:nearby_test_collector, {:stop, attrs})
      {:ok, %{discoverable: false}}
    end

    def send_nearby_request(attrs) do
      send(:nearby_test_collector, {:send_request, attrs})
      {:ok, %{request_id: "55555555-5555-4555-8555-555555555555", status: "pending"}}
    end

    def list_nearby_requests(_attrs) do
      {:ok,
       %{
         incoming: [
           %{
             request_id: "55555555-5555-4555-8555-555555555555",
             user_id: "22222222-2222-2222-2222-222222222222",
             created_at: "2026-08-25T00:00:00Z"
           }
         ],
         outgoing: [],
         connections: []
       }}
    end

    def respond_nearby_request(attrs) do
      send(:nearby_test_collector, {:respond, attrs})

      {:ok,
       %{
         request_id: "55555555-5555-4555-8555-555555555555",
         user_id: "22222222-2222-2222-2222-222222222222",
         status: if(attrs["decision"] == "accept", do: "accepted", else: "declined")
       }}
    end

    def get_public_profile(%{"user_id" => user_id}) do
      {:ok, %{user_id: user_id, display_name: "Nearby Person", avatar_media_id: nil, bio: nil}}
    end

    def get_privacy(_attrs), do: {:ok, %{profile_photo_visibility: "everyone"}}
  end

  defmodule ConversationOk do
    def either_blocked?(_attrs), do: {:ok, %{blocked: false}}

    # Accept's create-or-get (audit fix 1): the SAME find-or-create path every DM uses. Captured so
    # the test can assert the pair + tenant it was called with.
    def create_conversation(attrs) do
      send(:nearby_test_collector, {:conversation, attrs})
      {:ok, %{conversation_id: "conv-nearby-1", type: "direct", created: false}}
    end
  end

  defmodule ConversationBlocked do
    def either_blocked?(_attrs), do: {:ok, %{blocked: true}}
  end

  defmodule LimiterOk do
    def check_rate(_attrs), do: :ok
  end

  setup do
    Process.register(self(), :nearby_test_collector)

    keys = [
      auth_client_adapter: AuthStub,
      user_client_adapter: UserStub,
      conversation_client_adapter: ConversationOk,
      rate_limiter_adapter: LimiterOk
    ]

    previous = for {key, _} <- keys, into: %{}, do: {key, Application.get_env(:shared_infra, key)}
    for {key, value} <- keys, do: Application.put_env(:shared_infra, key, value)

    on_exit(fn ->
      for {key, value} <- previous do
        if value,
          do: Application.put_env(:shared_infra, key, value),
          else: Application.delete_env(:shared_infra, key)
      end
    end)
  end

  defp authed(method, path, params \\ %{}) do
    method
    |> conn(path, params)
    |> put_req_header("authorization", "Bearer token")
  end

  test "discover binds identity/app to the session and returns no coordinates" do
    params = %{
      "latitude" => 28.6139,
      "longitude" => 77.2090,
      "accuracy_m" => 12,
      "radius_m" => 100,
      "user_id" => "attacker-controlled"
    }

    conn = authed(:post, "/api/v1/nearby/discover", params) |> NearbyController.discover(params)
    assert conn.status == 200
    assert_receive {:discover, attrs}
    assert attrs["user_id"] == @me
    assert attrs["app_id"] == @app

    %{"people" => [person]} = Jason.decode!(conn.resp_body)
    assert person["user_id"] == @peer
    assert person["distance_bucket_m"] == 100
    refute Map.has_key?(person, "latitude")
    refute Map.has_key?(person, "longitude")
  end

  test "blocked users are hidden and cannot receive a request" do
    Application.put_env(:shared_infra, :conversation_client_adapter, ConversationBlocked)

    params = %{
      "latitude" => 28.6139,
      "longitude" => 77.2090,
      "accuracy_m" => 12,
      "radius_m" => 200
    }

    conn = authed(:post, "/api/v1/nearby/discover", params) |> NearbyController.discover(params)
    assert %{"people" => []} = Jason.decode!(conn.resp_body)

    send_params = %{"user_id" => @peer}

    conn =
      authed(:post, "/api/v1/nearby/requests", send_params)
      |> NearbyController.send_request(send_params)

    assert conn.status == 404
    refute_receive {:send_request, _}, 50
  end

  test "accept checks block state before mutating the request" do
    Application.put_env(:shared_infra, :conversation_client_adapter, ConversationBlocked)
    params = %{"request_id" => @request, "decision" => "accept"}

    conn =
      authed(:post, "/api/v1/nearby/requests/#{@request}/respond", params)
      |> NearbyController.respond(params)

    assert conn.status == 404
    refute_receive {:respond, _}, 50

    Application.put_env(:shared_infra, :conversation_client_adapter, ConversationOk)
    conn = authed(:post, "/respond", params) |> NearbyController.respond(params)
    assert conn.status == 200

    assert_receive {:respond,
                    %{"user_id" => @me, "request_id" => @request, "decision" => "accept"}}

    # ACCEPT OPENS THE CHAT (audit fix 1): the response carries the pair's conversation_id, minted
    # through the one existing direct find-or-create path (idempotency is that path's own tested
    # contract — `created: false` here IS the already-existed case passing through).
    assert %{"status" => "accepted", "conversation_id" => "conv-nearby-1"} =
             Jason.decode!(conn.resp_body)

    assert_receive {:conversation, conversation_attrs}
    assert conversation_attrs["type"] == "direct"
    assert conversation_attrs["created_by"] == @me
    assert conversation_attrs["participant_user_ids"] == [@peer]
  end

  test "stop is session-owned" do
    conn = authed(:delete, "/api/v1/nearby/presence") |> NearbyController.stop(%{})
    assert conn.status == 200
    assert_receive {:stop, %{"user_id" => @me}}
  end
end
