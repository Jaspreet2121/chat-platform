defmodule ApiGatewayWeb.AutoReplyControllerTest do
  @moduledoc """
  The settings surface (102), no DB: session identity/tenant ride into the store; a successful PATCH
  broadcasts auto_replies_changed; the typed validation errors map to their envelope codes
  (unsupported outside_business_hours prominently — the recorded follow-up); writes rate-limited.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.AutoReplyController

  @user "11111111-1111-1111-1111-111111111111"
  @app "44444444-4444-4444-8444-444444444444"

  defmodule AuthStub do
    @moduledoc false
    def current_session(%{"authorization" => "Bearer me"}),
      do:
        {:ok,
         %{
           user_id: "11111111-1111-1111-1111-111111111111",
           app_id: "44444444-4444-4444-8444-444444444444"
         }}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule UserStub do
    @moduledoc false
    def get_auto_replies(_attrs),
      do: {:ok, %{away: %{"enabled" => false}, greeting: %{"enabled" => false}}}

    def update_auto_replies(attrs) do
      send(:auto_reply_ctl_test, {:update, attrs})

      case Application.get_env(:api_gateway, :auto_reply_update_result, :ok) do
        :ok -> {:ok, %{away: attrs["away"] || %{}, greeting: attrs["greeting"] || %{}}}
        error -> error
      end
    end
  end

  defmodule LimiterOk do
    @moduledoc false
    def check_rate(_attrs), do: :ok
  end

  defmodule LimiterTrips do
    @moduledoc false
    def check_rate(_attrs), do: {:error, :rate_limited, 23}
  end

  setup do
    Process.register(self(), :auto_reply_ctl_test)

    keys = [
      auth_client_adapter: AuthStub,
      user_client_adapter: UserStub,
      rate_limiter_adapter: LimiterOk
    ]

    prev = for {k, _} <- keys, into: %{}, do: {k, Application.get_env(:shared_infra, k)}
    for {k, v} <- keys, do: Application.put_env(:shared_infra, k, v)

    on_exit(fn ->
      for {k, v} <- prev do
        if v,
          do: Application.put_env(:shared_infra, k, v),
          else: Application.delete_env(:shared_infra, k)
      end

      Application.delete_env(:api_gateway, :auto_reply_update_result)
    end)

    :ok
  end

  defp request(action, params, method \\ :patch) do
    method
    |> conn("/api/v1/auto-replies", params)
    |> put_req_header("authorization", "Bearer me")
    |> then(&AutoReplyController.call(&1, AutoReplyController.init(action)))
  end

  test "GET returns the defaults-applied settings; PATCH carries identity + tenant and broadcasts" do
    assert request(:show, %{}, :get).status == 200

    ApiGatewayWeb.Endpoint.subscribe("user:" <> @user)
    params = %{"greeting" => %{"enabled" => true, "body" => "Hi!"}}

    conn = request(:update, params)
    assert conn.status == 200

    assert_receive {:update, attrs}
    assert attrs["user_id"] == @user
    assert attrs["app_id"] == @app
    assert attrs["greeting"]["body"] == "Hi!"

    assert_receive %Phoenix.Socket.Broadcast{event: "auto_replies_changed"}
  end

  test "typed validation errors map to their envelope codes" do
    for {error, status, code} <- [
          {{:error, :auto_reply_unsupported_mode}, 400, "auto_reply.unsupported_mode"},
          {{:error, :auto_reply_body_required}, 400, "auto_reply.body_required"},
          {{:error, :auto_reply_invalid_schedule}, 400, "auto_reply.invalid_schedule"},
          {{:error, :auto_reply_too_many_exceptions}, 400, "auto_reply.too_many_exceptions"}
        ] do
      Application.put_env(:api_gateway, :auto_reply_update_result, error)
      conn = request(:update, %{"away" => %{"enabled" => true}})
      assert conn.status == status
      assert %{"error" => %{"code" => ^code}} = Jason.decode!(conn.resp_body)
    end
  end

  test "writes are rate-limited with Retry-After; reads are not" do
    Application.put_env(:shared_infra, :rate_limiter_adapter, LimiterTrips)

    conn = request(:update, %{"away" => %{"enabled" => false}})
    assert conn.status == 429
    assert get_resp_header(conn, "retry-after") == ["23"]

    assert request(:show, %{}, :get).status == 200
  end
end
