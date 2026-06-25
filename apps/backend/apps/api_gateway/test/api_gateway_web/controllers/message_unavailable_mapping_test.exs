defmodule ApiGatewayWeb.MessageUnavailableMappingTest.SessionOkStub do
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

defmodule ApiGatewayWeb.MessageUnavailableMappingTest.MsgUnavailableStub do
  @moduledoc false
  @behaviour SharedInfra.MessageClient
  for fun <- [
        :create_message,
        :send_message,
        :list_messages,
        :list_timeline,
        :update_message,
        :edit_message,
        :delete_message,
        :mark_read,
        :mark_delivered,
        :analytics_overview,
        :analytics_timeseries,
        :admin_delete_message,
        :add_reaction,
        :remove_reaction
      ] do
    @impl true
    def unquote(fun)(_attrs), do: {:error, :message_unavailable}
  end
end

defmodule ApiGatewayWeb.MessageUnavailableMappingTest do
  @moduledoc """
  Plain (Docker-free, no network): with the Message client returning `{:error, :message_unavailable}`
  (valid session), the gateway maps it to HTTP 503. Uses `POST /:id/read` (no body, no membership
  check) with message_persistence enabled so the controller takes the path that calls MessageClient.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ApiGatewayWeb.MessageUnavailableMappingTest.{MsgUnavailableStub, SessionOkStub}

  @opts ApiGatewayWeb.Router.init([])

  setup do
    prev_auth = Application.get_env(:shared_infra, :auth_client_adapter)
    prev_msg = Application.get_env(:shared_infra, :message_client_adapter)
    prev_persist = Application.get_env(:message_service, :message_persistence, false)

    Application.put_env(:shared_infra, :auth_client_adapter, SessionOkStub)
    Application.put_env(:shared_infra, :message_client_adapter, MsgUnavailableStub)
    Application.put_env(:message_service, :message_persistence, true)

    on_exit(fn ->
      restore(:shared_infra, :auth_client_adapter, prev_auth)
      restore(:shared_infra, :message_client_adapter, prev_msg)
      Application.put_env(:message_service, :message_persistence, prev_persist)
    end)

    :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, val), do: Application.put_env(app, key, val)

  test "POST /:id/read → 503 message.unavailable when message svc unreachable" do
    conn =
      conn(:post, "/api/v1/conversations/c1/messages/m1/read")
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer x")
      |> ApiGatewayWeb.Router.call(@opts)

    assert conn.status == 503
    assert %{"error" => %{"code" => "message.unavailable"}} = Jason.decode!(conn.resp_body)
  end
end
