defmodule ApiGatewayWeb.ClientConfigControllerTest do
  @moduledoc """
  GET /api/v1/client-config (109), no DB: the session's app_id rides into the store, and the
  response is the tiny {e2ee_default} shape (default false when the store says so).
  """
  use ExUnit.Case, async: false

  import Plug.Test

  alias ApiGatewayWeb.ClientConfigController

  defmodule AuthStub do
    def current_session(%{"authorization" => "Bearer on"}),
      do: {:ok, %{user_id: "u", app_id: "44444444-4444-4444-8444-444444444444"}}

    def current_session(%{"authorization" => "Bearer off"}),
      do: {:ok, %{user_id: "u", app_id: "55555555-5555-4555-8555-555555555555"}}

    def current_session(_), do: {:error, :session_invalid}

    def client_config(%{"app_id" => "44444444-4444-4444-8444-444444444444"}),
      do: {:ok, %{e2ee_default: true}}

    def client_config(_), do: {:ok, %{e2ee_default: false}}
  end

  setup do
    prev = Application.get_env(:shared_infra, :auth_client_adapter)
    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:shared_infra, :auth_client_adapter, prev),
        else: Application.delete_env(:shared_infra, :auth_client_adapter)
    end)

    :ok
  end

  defp get(token) do
    :get
    |> conn("/api/v1/client-config")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
    |> ClientConfigController.show(%{})
  end

  test "default-on app → e2ee_default true; other app → false; no session → 401" do
    conn = get("on")
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"e2ee_default" => true}

    conn = get("off")
    assert Jason.decode!(conn.resp_body) == %{"e2ee_default" => false}

    conn = get("nope")
    assert conn.status == 401
  end
end
