defmodule ApiGatewayWeb.ConversationUnavailableMappingTest.SessionOkStub do
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
end

defmodule ApiGatewayWeb.ConversationUnavailableMappingTest.ConvUnavailableStub do
  @moduledoc false
  @behaviour SharedInfra.ConversationClient
  @impl true
  def create_conversation(_attrs), do: {:error, :conversation_unavailable}
  @impl true
  def list_conversations(_attrs), do: {:error, :conversation_unavailable}
  @impl true
  def get_conversation(_attrs), do: {:error, :conversation_unavailable}
  @impl true
  def add_participant(_attrs), do: {:error, :conversation_unavailable}
  @impl true
  def remove_participant(_attrs), do: {:error, :conversation_unavailable}
end

defmodule ApiGatewayWeb.ConversationUnavailableMappingTest do
  @moduledoc """
  Plain (Docker-free, no network): with the Conversation client returning
  `{:error, :conversation_unavailable}` (and a valid session), the gateway maps it to HTTP 503 —
  not a 403/400. conversation_persistence is enabled so the controller takes the auth+conversation
  path (which carries the mapping). Routed through the real Router.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ApiGatewayWeb.ConversationUnavailableMappingTest.{ConvUnavailableStub, SessionOkStub}

  @opts ApiGatewayWeb.Router.init([])

  setup do
    prev_auth = Application.get_env(:shared_infra, :auth_client_adapter)
    prev_conv = Application.get_env(:shared_infra, :conversation_client_adapter)
    prev_persist = Application.get_env(:conversation_service, :conversation_persistence, false)

    Application.put_env(:shared_infra, :auth_client_adapter, SessionOkStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvUnavailableStub)
    Application.put_env(:conversation_service, :conversation_persistence, true)

    on_exit(fn ->
      restore(:shared_infra, :auth_client_adapter, prev_auth)
      restore(:shared_infra, :conversation_client_adapter, prev_conv)
      Application.put_env(:conversation_service, :conversation_persistence, prev_persist)
    end)

    :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, val), do: Application.put_env(app, key, val)

  test "GET /api/v1/conversations/:id → 503 conversation.unavailable when conversation svc unreachable" do
    conn =
      conn(:get, "/api/v1/conversations/conv_1")
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer x")
      |> ApiGatewayWeb.Router.call(@opts)

    assert conn.status == 503
    assert %{"error" => %{"code" => "conversation.unavailable"}} = Jason.decode!(conn.resp_body)
  end
end
