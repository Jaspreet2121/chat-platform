defmodule ApiGatewayWeb.CallHistoryNameTest.AuthStub do
  @moduledoc false
  @app "44444444-4444-4444-8444-444444444444"
  def current_session(_attrs), do: {:ok, %{user_id: "me-1", app_id: @app}}
end

defmodule ApiGatewayWeb.CallHistoryNameTest.CallsStub do
  @moduledoc false
  # One direct call where the current user is the caller → the counterpart is the callee.
  def list_calls_for_user(_attrs) do
    {:ok,
     %{
       calls: [
         %{
           id: "call-1",
           room_name: "room-1",
           kind: "direct",
           caller_id: "me-1",
           callee_id: "peer-1",
           conversation_id: "conv-1",
           type: "voice",
           status: "ended",
           created_at: "2026-07-10T00:00:00Z"
         }
       ]
     }}
  end
end

defmodule ApiGatewayWeb.CallHistoryNameTest.NamedProfileStub do
  @moduledoc false
  @app "44444444-4444-4444-8444-444444444444"
  # App-scoped: only resolves when app_id is threaded through — if the controller omitted it (the bug),
  # this clause misses and the counterpart name comes back nil.
  def get_public_profile(%{"user_id" => uid, "app_id" => @app}),
    do: {:ok, %{user_id: uid, display_name: "Grace Hopper", avatar_media_id: nil}}

  def get_public_profile(_), do: {:error, :profile_invalid}
end

defmodule ApiGatewayWeb.CallHistoryNameTest.CrossTenantProfileStub do
  @moduledoc false
  # Models a counterpart not in the caller's app → app-scoped lookup 404s.
  def get_public_profile(_attrs), do: {:error, :profile_not_found}
end

defmodule ApiGatewayWeb.CallHistoryNameTest do
  @moduledoc """
  Docker-free: GET /api/v1/calls enriches each row with the counterpart's display name. get_public_profile is
  app-scoped (a1ce358), so the controller MUST thread the caller's session app_id — otherwise every name is
  silently nil. Same-app → the name; cross-tenant/unknown → nil counterpart_name, still 200 (client falls
  back to a short id/initials).
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ApiGatewayWeb.CallHistoryNameTest.AuthStub
  alias ApiGatewayWeb.CallHistoryNameTest.CallsStub
  alias ApiGatewayWeb.CallHistoryNameTest.CrossTenantProfileStub
  alias ApiGatewayWeb.CallHistoryNameTest.NamedProfileStub

  @opts ApiGatewayWeb.Router.init([])

  setup do
    prev_auth = Application.get_env(:shared_infra, :auth_client_adapter)
    prev_conv = Application.get_env(:shared_infra, :conversation_client_adapter)
    prev_user = Application.get_env(:shared_infra, :user_client_adapter)

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, CallsStub)

    on_exit(fn ->
      restore(:auth_client_adapter, prev_auth)
      restore(:conversation_client_adapter, prev_conv)
      restore(:user_client_adapter, prev_user)
    end)

    :ok
  end

  test "same-app counterpart → 200 with the resolved counterpart_name (proves app_id is threaded)" do
    Application.put_env(:shared_infra, :user_client_adapter, NamedProfileStub)

    [row] = index_calls()

    assert row["counterpart_id"] == "peer-1"
    assert row["counterpart_name"] == "Grace Hopper"
  end

  test "cross-tenant / unknown counterpart → 200 with counterpart_name nil (client falls back)" do
    Application.put_env(:shared_infra, :user_client_adapter, CrossTenantProfileStub)

    [row] = index_calls()

    assert row["counterpart_id"] == "peer-1"
    assert row["counterpart_name"] == nil
  end

  defp index_calls do
    conn(:get, "/api/v1/calls")
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer me-session")
    |> ApiGatewayWeb.Router.call(@opts)
    |> then(fn conn ->
      assert conn.status == 200
      Jason.decode!(conn.resp_body)["calls"]
    end)
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)
end
