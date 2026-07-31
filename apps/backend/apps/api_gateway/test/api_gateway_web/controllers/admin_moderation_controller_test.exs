defmodule ApiGatewayWeb.AdminModerationControllerTest.AdminAuthStub do
  @moduledoc false
  @behaviour SharedInfra.AuthClient
  @session %{
    user_id: "admin-1",
    session_id: "s",
    device_id: "d",
    platform: "web",
    is_admin: true,
    role: "admin"
  }

  @impl true
  def current_session(_attrs), do: {:ok, @session}
  @impl true
  def list_users(_attrs),
    do: {:ok, %{page: 1, page_size: 25, users: [%{user_id: "u1", status: "active"}]}}

  @impl true
  def get_user_detail(attrs),
    do:
      {:ok,
       %{
         auth: %{user_id: attrs["user_id"], status: "active", is_admin: false},
         profile: %{display_name: "Test"},
         stats: %{conversations: 1, messages_sent: 2, media: 0, storage_bytes: 0},
         enforcement: [],
         reports: %{against: [], by: []}
       }}

  @impl true
  def suspend_user(attrs), do: {:ok, %{user_id: attrs["user_id"], status: "suspended"}}
  @impl true
  def reactivate_user(attrs), do: {:ok, %{user_id: attrs["user_id"], status: "active"}}
  @impl true
  def ban_user(attrs), do: {:ok, %{user_id: attrs["user_id"], status: "suspended"}}
  @impl true
  def list_reports(_attrs), do: {:ok, %{page: 1, page_size: 25, reports: []}}
  @impl true
  def update_report(attrs), do: {:ok, %{id: attrs["report_id"], status: attrs["status"]}}
  @impl true
  def write_audit(_attrs), do: {:ok, %{written: true}}
  @impl true
  def list_audit(_attrs), do: {:ok, %{page: 1, page_size: 50, entries: []}}
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
end

defmodule ApiGatewayWeb.AdminModerationControllerTest.NonAdminAuthStub do
  @moduledoc false
  @behaviour SharedInfra.AuthClient
  @session %{user_id: "u", session_id: "s", device_id: "d", platform: "web", is_admin: false}

  @impl true
  def current_session(_attrs), do: {:ok, @session}

  for fun <- [
        :list_users,
        :get_user_detail,
        :suspend_user,
        :reactivate_user,
        :ban_user,
        :list_reports,
        :update_report,
        :write_audit,
        :list_audit,
        :request_otp,
        :verify_otp,
        :refresh,
        :revoke
      ] do
    @impl true
    def unquote(fun)(_attrs), do: {:ok, %{}}
  end

  @impl true
  def persistence_enabled?, do: true
end

defmodule ApiGatewayWeb.AdminModerationControllerTest do
  @moduledoc """
  Plain (Docker-free): the moderation endpoints are admin-gated and proxy auth-service. Admin reaches
  list/suspend (200, proxied shapes); a non-admin is rejected (403). Stubs only — the real mutations +
  audit are validated by the live curl smoke test.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ApiGatewayWeb.AdminModerationControllerTest.{AdminAuthStub, NonAdminAuthStub}

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

  defp call(method, path, body \\ nil) do
    base =
      conn(method, path, body)
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer x")

    base = if body, do: put_req_header(base, "content-type", "application/json"), else: base
    ApiGatewayWeb.Router.call(base, @opts)
  end

  test "admin lists users (200, proxied)" do
    Application.put_env(:shared_infra, :auth_client_adapter, AdminAuthStub)
    conn = call(:get, "/api/v1/admin/users")

    assert conn.status == 200
    assert %{"users" => [%{"user_id" => "u1"}]} = Jason.decode!(conn.resp_body)
  end

  test "admin gets a user detail (200, aggregated shape)" do
    Application.put_env(:shared_infra, :auth_client_adapter, AdminAuthStub)
    conn = call(:get, "/api/v1/admin/users/u1")

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["auth"]["user_id"] == "u1"
    assert is_map(body["stats"])
    assert is_list(body["enforcement"])
    assert is_map(body["reports"])
  end

  test "admin suspends a user (200, suspended)" do
    Application.put_env(:shared_infra, :auth_client_adapter, AdminAuthStub)
    conn = call(:post, "/api/v1/admin/users/u9/suspend", Jason.encode!(%{"reason" => "spam"}))

    assert conn.status == 200
    assert %{"user_id" => "u9", "status" => "suspended"} = Jason.decode!(conn.resp_body)
  end

  test "non-admin is rejected from moderation (403)" do
    Application.put_env(:shared_infra, :auth_client_adapter, NonAdminAuthStub)
    conn = call(:get, "/api/v1/admin/users")

    assert conn.status == 403
    assert %{"error" => %{"code" => "admin.forbidden"}} = Jason.decode!(conn.resp_body)
  end
end
