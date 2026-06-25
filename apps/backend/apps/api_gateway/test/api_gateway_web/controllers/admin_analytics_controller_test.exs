defmodule ApiGatewayWeb.AdminAnalyticsControllerTest.AdminSessionStub do
  @moduledoc false
  @behaviour SharedInfra.AuthClient
  @session %{user_id: "admin", session_id: "s", device_id: "d", platform: "web", is_admin: true}
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

defmodule ApiGatewayWeb.AdminAnalyticsControllerTest.NonAdminSessionStub do
  @moduledoc false
  @behaviour SharedInfra.AuthClient
  @session %{user_id: "u", session_id: "s", device_id: "d", platform: "web", is_admin: false}
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

defmodule ApiGatewayWeb.AdminAnalyticsControllerTest.AnalyticsStub do
  @moduledoc false
  @behaviour SharedInfra.MessageClient

  @overview %{
    totals: %{users: 3, conversations: 2, messages: 7, media: 1, storage_bytes: 29},
    activity: %{messages_24h: 7, messages_7d: 7, active_conversations_7d: 2},
    auth: %{login_success_7d: 5, login_failure_7d: 0}
  }
  @series %{
    days: 30,
    signups: [%{date: "2026-06-25", count: 3}],
    messages: [%{date: "2026-06-25", count: 7}],
    conversations: [%{date: "2026-06-25", count: 2}]
  }

  @impl true
  def analytics_overview(_attrs), do: {:ok, @overview}
  @impl true
  def analytics_timeseries(_attrs), do: {:ok, @series}

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
        :admin_delete_message,
        :add_reaction,
        :remove_reaction
      ] do
    @impl true
    def unquote(fun)(_attrs), do: {:error, :message_unavailable}
  end
end

defmodule ApiGatewayWeb.AdminAnalyticsControllerTest do
  @moduledoc """
  Plain (Docker-free): the analytics endpoints sit behind RequireAdmin and proxy the message client.
  An admin reaches them (200 with the proxied shape); a non-admin is rejected (403). Uses stubs, so no
  DB/network — the real SQL is validated by the live curl smoke test.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ApiGatewayWeb.AdminAnalyticsControllerTest.{
    AdminSessionStub,
    AnalyticsStub,
    NonAdminSessionStub
  }

  @opts ApiGatewayWeb.Router.init([])

  setup do
    prev_auth = Application.get_env(:shared_infra, :auth_client_adapter)
    prev_msg = Application.get_env(:shared_infra, :message_client_adapter)
    Application.put_env(:shared_infra, :message_client_adapter, AnalyticsStub)

    on_exit(fn ->
      restore(:auth_client_adapter, prev_auth)
      restore(:message_client_adapter, prev_msg)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, val), do: Application.put_env(:shared_infra, key, val)

  defp get(path) do
    conn(:get, path)
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer x")
    |> ApiGatewayWeb.Router.call(@opts)
  end

  test "admin gets analytics overview (200, proxied shape)" do
    Application.put_env(:shared_infra, :auth_client_adapter, AdminSessionStub)
    conn = get("/api/v1/admin/analytics/overview")

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["totals"]["users"] == 3
    assert body["activity"]["messages_24h"] == 7
  end

  test "admin gets analytics timeseries (200)" do
    Application.put_env(:shared_infra, :auth_client_adapter, AdminSessionStub)
    conn = get("/api/v1/admin/analytics/timeseries?days=30")

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["days"] == 30
    assert [%{"date" => _, "count" => 7}] = body["messages"]
  end

  test "non-admin is rejected from analytics (403)" do
    Application.put_env(:shared_infra, :auth_client_adapter, NonAdminSessionStub)
    conn = get("/api/v1/admin/analytics/overview")

    assert conn.status == 403
    assert %{"error" => %{"code" => "admin.forbidden"}} = Jason.decode!(conn.resp_body)
  end
end
