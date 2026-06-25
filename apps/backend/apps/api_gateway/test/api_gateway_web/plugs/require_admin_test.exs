defmodule ApiGatewayWeb.RequireAdminTest.AdminSessionStub do
  @moduledoc false
  @behaviour SharedInfra.AuthClient
  @session %{
    user_id: "admin_user",
    session_id: "s-admin",
    device_id: "d",
    platform: "web",
    is_admin: true,
    issued_at: "x",
    expires_at: "y"
  }
  @impl true
  def current_session(_attrs), do: {:ok, @session}
  @impl true
  def persistence_enabled?, do: true
  @impl true
  def request_otp(_attrs), do: {:ok, %{}}
  @impl true
  def verify_otp(_attrs), do: {:ok, %{}}
  @impl true
  def refresh(_attrs), do: {:ok, %{}}
  @impl true
  def revoke(_attrs), do: {:ok, %{}}

  for fun <- [
        :list_users,
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

defmodule ApiGatewayWeb.RequireAdminTest.NonAdminSessionStub do
  @moduledoc false
  @behaviour SharedInfra.AuthClient
  @session %{
    user_id: "normal_user",
    session_id: "s-normal",
    device_id: "d",
    platform: "web",
    is_admin: false,
    issued_at: "x",
    expires_at: "y"
  }
  @impl true
  def current_session(_attrs), do: {:ok, @session}
  @impl true
  def persistence_enabled?, do: true
  @impl true
  def request_otp(_attrs), do: {:ok, %{}}
  @impl true
  def verify_otp(_attrs), do: {:ok, %{}}
  @impl true
  def refresh(_attrs), do: {:ok, %{}}
  @impl true
  def revoke(_attrs), do: {:ok, %{}}

  for fun <- [
        :list_users,
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

defmodule ApiGatewayWeb.RequireAdminTest do
  @moduledoc """
  Plain (Docker-free): proves the admin gate end-to-end via a stubbed auth client — an admin session
  reaches GET /api/v1/admin/me (200, is_admin true), a non-admin session is rejected (403), and a
  request with no bearer is rejected (401). Standard error envelope on the rejections.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ApiGatewayWeb.RequireAdminTest.{AdminSessionStub, NonAdminSessionStub}

  @opts ApiGatewayWeb.Router.init([])

  defp with_auth_adapter(adapter) do
    prev = Application.get_env(:shared_infra, :auth_client_adapter)
    Application.put_env(:shared_infra, :auth_client_adapter, adapter)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:shared_infra, :auth_client_adapter, prev),
        else: Application.delete_env(:shared_infra, :auth_client_adapter)
    end)
  end

  defp call_admin_me(headers) do
    Enum.reduce(headers, conn(:get, "/api/v1/admin/me"), fn {k, v}, c ->
      put_req_header(c, k, v)
    end)
    |> ApiGatewayWeb.Router.call(@opts)
  end

  test "admin session reaches /admin/me → 200 with is_admin true" do
    with_auth_adapter(AdminSessionStub)

    conn = call_admin_me([{"accept", "application/json"}, {"authorization", "Bearer x"}])

    assert conn.status == 200
    assert %{"is_admin" => true, "user_id" => "admin_user"} = Jason.decode!(conn.resp_body)
  end

  test "non-admin session is rejected → 403 admin.forbidden" do
    with_auth_adapter(NonAdminSessionStub)

    conn = call_admin_me([{"accept", "application/json"}, {"authorization", "Bearer x"}])

    assert conn.status == 403
    assert %{"error" => %{"code" => "admin.forbidden"}} = Jason.decode!(conn.resp_body)
  end

  test "no bearer token is rejected → 401 admin.unauthorized" do
    with_auth_adapter(NonAdminSessionStub)

    conn = call_admin_me([{"accept", "application/json"}])

    assert conn.status == 401
    assert %{"error" => %{"code" => "admin.unauthorized"}} = Jason.decode!(conn.resp_body)
  end
end
