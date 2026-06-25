defmodule ApiGatewayWeb.MediaUnavailableMappingTest.SessionOkStub do
  @moduledoc false
  @behaviour SharedInfra.AuthClient
  @session %{
    user_id: "user_1",
    session_id: "s",
    device_id: "d",
    platform: "ios",
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

defmodule ApiGatewayWeb.MediaUnavailableMappingTest.MediaUnavailableStub do
  @moduledoc false
  @behaviour SharedInfra.MediaClient
  @impl true
  def create_upload(_attrs), do: {:error, :media_unavailable}
  @impl true
  def complete_upload(_attrs), do: {:error, :media_unavailable}
  @impl true
  def get_download_url(_attrs), do: {:error, :media_unavailable}
end

defmodule ApiGatewayWeb.MediaUnavailableMappingTest do
  @moduledoc """
  Plain (Docker-free, no network): with the Media client returning `{:error, :media_unavailable}`
  (valid session), the gateway maps it to HTTP 503. Uses `GET /:media_id/download` (no body) with
  media_persistence enabled so the controller takes the path that calls MediaClient.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ApiGatewayWeb.MediaUnavailableMappingTest.{MediaUnavailableStub, SessionOkStub}

  @opts ApiGatewayWeb.Router.init([])

  setup do
    prev_auth = Application.get_env(:shared_infra, :auth_client_adapter)
    prev_media = Application.get_env(:shared_infra, :media_client_adapter)
    prev_persist = Application.get_env(:media_service, :media_persistence, false)

    Application.put_env(:shared_infra, :auth_client_adapter, SessionOkStub)
    Application.put_env(:shared_infra, :media_client_adapter, MediaUnavailableStub)
    Application.put_env(:media_service, :media_persistence, true)

    on_exit(fn ->
      restore(:shared_infra, :auth_client_adapter, prev_auth)
      restore(:shared_infra, :media_client_adapter, prev_media)
      Application.put_env(:media_service, :media_persistence, prev_persist)
    end)

    :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, val), do: Application.put_env(app, key, val)

  test "GET /:media_id/download → 503 media.unavailable when media svc unreachable" do
    conn =
      conn(:get, "/api/v1/media/m1/download")
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer x")
      |> ApiGatewayWeb.Router.call(@opts)

    assert conn.status == 503
    assert %{"error" => %{"code" => "media.unavailable"}} = Jason.decode!(conn.resp_body)
  end
end
