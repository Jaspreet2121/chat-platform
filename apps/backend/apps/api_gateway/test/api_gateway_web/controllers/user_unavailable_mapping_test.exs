defmodule ApiGatewayWeb.UserUnavailableMappingTest.UserUnavailableStub do
  @moduledoc false
  @behaviour SharedInfra.UserClient
  @impl true
  def get_current_profile(_attrs), do: {:error, :user_unavailable}
  @impl true
  def get_public_profile(_attrs), do: {:error, :user_unavailable}
  @impl true
  def update_current_profile(_attrs), do: {:error, :user_unavailable}
end

defmodule ApiGatewayWeb.UserUnavailableMappingTest.AuthOkStub do
  @moduledoc false
  @behaviour SharedInfra.AuthClient
  @impl true
  def current_session(_attrs),
    do: {:ok, %{user_id: "viewer", app_id: "00000000-0000-0000-0000-000000000001"}}

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

defmodule ApiGatewayWeb.UserUnavailableMappingTest do
  @moduledoc """
  Plain (Docker-free, no network): with a valid session but the User client returning
  `{:error, :user_unavailable}`, the gateway maps it to HTTP 503. `/profile` is session-gated now, so the
  request carries a stubbed session before reaching `UserClient.get_public_profile`.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ApiGatewayWeb.UserUnavailableMappingTest.AuthOkStub
  alias ApiGatewayWeb.UserUnavailableMappingTest.UserUnavailableStub

  @opts ApiGatewayWeb.Router.init([])

  setup do
    previous = Application.get_env(:shared_infra, :user_client_adapter)
    prev_auth = Application.get_env(:shared_infra, :auth_client_adapter)
    Application.put_env(:shared_infra, :user_client_adapter, UserUnavailableStub)
    Application.put_env(:shared_infra, :auth_client_adapter, AuthOkStub)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:shared_infra, :user_client_adapter, previous),
        else: Application.delete_env(:shared_infra, :user_client_adapter)

      if prev_auth,
        do: Application.put_env(:shared_infra, :auth_client_adapter, prev_auth),
        else: Application.delete_env(:shared_infra, :auth_client_adapter)
    end)

    :ok
  end

  test "GET /api/v1/users/:id/profile → 503 user.unavailable when user svc unreachable" do
    conn =
      conn(:get, "/api/v1/users/user_1/profile")
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer viewer")
      |> ApiGatewayWeb.Router.call(@opts)

    assert conn.status == 503
    assert %{"error" => %{"code" => "user.unavailable"}} = Jason.decode!(conn.resp_body)
  end
end
