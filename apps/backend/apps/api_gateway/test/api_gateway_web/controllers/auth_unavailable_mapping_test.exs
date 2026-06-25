defmodule ApiGatewayWeb.AuthUnavailableStub do
  @moduledoc false
  # Stand-in Auth client that simulates the HTTP adapter when auth-service is unreachable:
  # every call returns the transport-failure result. No network involved.
  @behaviour SharedInfra.AuthClient

  @impl true
  def current_session(_attrs), do: {:error, :auth_unavailable}
  @impl true
  def persistence_enabled?, do: false
  @impl true
  def request_otp(_attrs), do: {:error, :auth_unavailable}
  @impl true
  def verify_otp(_attrs), do: {:error, :auth_unavailable}
  @impl true
  def refresh(_attrs), do: {:error, :auth_unavailable}
  @impl true
  def revoke(_attrs), do: {:error, :auth_unavailable}

  for fun <- [
        :list_users,
        :get_user_detail,
        :suspend_user,
        :reactivate_user,
        :ban_user,
        :list_reports,
        :update_report,
        :write_audit,
        :list_audit
      ] do
    @impl true
    def unquote(fun)(_attrs), do: {:error, :auth_unavailable}
  end
end

defmodule ApiGatewayWeb.AuthUnavailableMappingTest do
  @moduledoc """
  Plain (Docker-free, no network): with the Auth client returning `{:error, :auth_unavailable}`,
  the gateway maps it to HTTP 503 via `ErrorResponse.service_unavailable/2` — additively, without
  disturbing the existing error-atom clauses. Routed through the real Router (mirrors the
  rate-limit controller test).
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  @opts ApiGatewayWeb.Router.init([])

  setup do
    previous = Application.get_env(:shared_infra, :auth_client_adapter)
    Application.put_env(:shared_infra, :auth_client_adapter, ApiGatewayWeb.AuthUnavailableStub)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:shared_infra, :auth_client_adapter, previous),
        else: Application.delete_env(:shared_infra, :auth_client_adapter)
    end)

    :ok
  end

  test "GET /api/v1/auth/session → 503 auth.unavailable when auth is unreachable" do
    conn =
      conn(:get, "/api/v1/auth/session")
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer x")
      |> ApiGatewayWeb.Router.call(@opts)

    assert conn.status == 503
    assert %{"error" => %{"code" => "auth.unavailable"}} = Jason.decode!(conn.resp_body)
  end

  test "ErrorResponse.service_unavailable/2 builds the 503 envelope" do
    conn =
      conn(:get, "/")
      |> ApiGatewayWeb.ErrorResponse.service_unavailable("auth.unavailable")

    assert conn.status == 503
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "auth.unavailable"
    assert is_binary(body["error"]["message"])
  end
end
