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

defmodule ApiGatewayWeb.UserUnavailableMappingTest do
  @moduledoc """
  Plain (Docker-free, no network): with the User client returning `{:error, :user_unavailable}`, the
  gateway maps it to HTTP 503. Uses `GET /api/v1/users/:id/profile` (public profile — not persistence-
  gated, no auth/body), which routes straight to `UserClient.get_public_profile`.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ApiGatewayWeb.UserUnavailableMappingTest.UserUnavailableStub

  @opts ApiGatewayWeb.Router.init([])

  setup do
    previous = Application.get_env(:shared_infra, :user_client_adapter)
    Application.put_env(:shared_infra, :user_client_adapter, UserUnavailableStub)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:shared_infra, :user_client_adapter, previous),
        else: Application.delete_env(:shared_infra, :user_client_adapter)
    end)

    :ok
  end

  test "GET /api/v1/users/:id/profile → 503 user.unavailable when user svc unreachable" do
    conn =
      conn(:get, "/api/v1/users/user_1/profile")
      |> put_req_header("accept", "application/json")
      |> ApiGatewayWeb.Router.call(@opts)

    assert conn.status == 503
    assert %{"error" => %{"code" => "user.unavailable"}} = Jason.decode!(conn.resp_body)
  end
end
