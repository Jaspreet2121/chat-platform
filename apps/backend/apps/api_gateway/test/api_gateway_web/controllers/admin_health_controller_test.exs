defmodule ApiGatewayWeb.AdminHealthControllerTest.AdminStub do
  @moduledoc false
  @behaviour SharedInfra.AuthClient
  @session %{user_id: "admin", session_id: "s", device_id: "d", platform: "web", is_admin: true}

  @impl true
  def current_session(_attrs), do: {:ok, @session}
  @impl true
  def persistence_enabled?, do: true

  for fun <- [
        :request_otp,
        :verify_otp,
        :refresh,
        :revoke,
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
    def unquote(fun)(_attrs), do: {:ok, %{}}
  end
end

defmodule ApiGatewayWeb.AdminHealthControllerTest.NonAdminStub do
  @moduledoc false
  @behaviour SharedInfra.AuthClient
  @session %{user_id: "u", session_id: "s", device_id: "d", platform: "web", is_admin: false}

  @impl true
  def current_session(_attrs), do: {:ok, @session}
  @impl true
  def persistence_enabled?, do: true

  for fun <- [
        :request_otp,
        :verify_otp,
        :refresh,
        :revoke,
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
    def unquote(fun)(_attrs), do: {:ok, %{}}
  end
end

defmodule ApiGatewayWeb.AdminHealthControllerTest do
  @moduledoc """
  Plain (Docker-free): admin reaches GET /api/v1/admin/health and gets the aggregated shape (200 even
  when deps are unreachable — down is data, not an error, with no service URLs set in test so no
  network is attempted). Non-admin is rejected (403). Live all-up is validated by the curl smoke test.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ApiGatewayWeb.AdminHealthControllerTest.{AdminStub, NonAdminStub}

  @opts ApiGatewayWeb.Router.init([])

  setup do
    prev = Application.get_env(:shared_infra, :auth_client_adapter)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:shared_infra, :auth_client_adapter, prev),
        else: Application.delete_env(:shared_infra, :auth_client_adapter)
    end)

    :ok
  end

  defp get_health do
    conn(:get, "/api/v1/admin/health")
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer x")
    |> ApiGatewayWeb.Router.call(@opts)
  end

  test "admin gets aggregated health (200, full shape)" do
    Application.put_env(:shared_infra, :auth_client_adapter, AdminStub)
    conn = get_health()

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["status"] in ["healthy", "degraded", "down"]
    assert is_map(body["dependencies"]["postgres"])
    assert is_map(body["dependencies"]["kafka"])
    assert is_map(body["dependencies"]["minio"])
    assert is_list(body["services"])
    assert is_binary(body["checked_at"])
  end

  test "non-admin is rejected (403)" do
    Application.put_env(:shared_infra, :auth_client_adapter, NonAdminStub)
    conn = get_health()

    assert conn.status == 403
    assert %{"error" => %{"code" => "admin.forbidden"}} = Jason.decode!(conn.resp_body)
  end
end
