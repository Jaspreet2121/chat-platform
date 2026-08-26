defmodule ApiGatewayWeb.BornSecretTest do
  @moduledoc """
  Born-secret side effects at 1:1 CREATE (109), no DB: when the conversation-service returns a
  genuine insert that is `secret: true` (the opportunistic auto-upgrade), the gateway emits the
  SAME encryption-enabled system message + conversation_encryption_changed fan-out as a manual
  toggle — and does NEITHER for a normal create or an idempotent existing-direct return.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.ConversationController

  @me "11111111-1111-1111-1111-111111111111"
  @peer "22222222-2222-2222-2222-222222222222"
  @conv "33333333-3333-3333-3333-333333333333"

  defmodule AuthStub do
    def current_session(%{"authorization" => "Bearer token"}),
      do: {:ok, %{user_id: "11111111-1111-1111-1111-111111111111", app_id: "app"}}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule ConversationStub do
    def create_conversation(_attrs) do
      Application.get_env(:api_gateway, :test_create_response)
    end
  end

  defmodule MessageStub do
    def create_message(attrs) do
      send(:born_test, {:system_message, attrs})
      {:ok, Map.put(attrs, "message_id", "sys-1")}
    end
  end

  setup do
    Process.register(self(), :born_test)
    Application.put_env(:conversation_service, :conversation_persistence, true)

    keys = [
      auth_client_adapter: AuthStub,
      conversation_client_adapter: ConversationStub,
      message_client_adapter: MessageStub
    ]

    prev = for {k, _} <- keys, into: %{}, do: {k, Application.get_env(:shared_infra, k)}
    for {k, v} <- keys, do: Application.put_env(:shared_infra, k, v)

    on_exit(fn ->
      for {k, v} <- prev do
        if v,
          do: Application.put_env(:shared_infra, k, v),
          else: Application.delete_env(:shared_infra, k)
      end

      Application.delete_env(:api_gateway, :test_create_response)
      Application.delete_env(:conversation_service, :conversation_persistence)
    end)

    :ok
  end

  defp create do
    :post
    |> conn("/api/v1/conversations", %{
      "type" => "direct",
      "participant_user_ids" => [@peer]
    })
    |> put_req_header("authorization", "Bearer token")
    |> ConversationController.create(%{
      "type" => "direct",
      "participant_user_ids" => [@peer]
    })
  end

  test "a BORN-SECRET genuine insert emits the system message + notifies both members" do
    Application.put_env(:api_gateway, :test_create_response, {
      :ok,
      %{
        conversation_id: @conv,
        created: true,
        secret: true,
        participant_user_ids: [@me, @peer]
      }
    })

    ApiGatewayWeb.Endpoint.subscribe("user:" <> @me)
    ApiGatewayWeb.Endpoint.subscribe("user:" <> @peer)

    conn = create()
    assert conn.status == 201

    assert_receive {:system_message, message}
    assert message["message_type"] == "system"
    assert message["metadata"] == %{"kind" => "encryption", "state" => "enabled", "by" => @me}

    expected = %{
      "type" => "conversation_encryption_changed",
      "conversation_id" => @conv,
      "enabled" => true
    }

    assert_receive %Phoenix.Socket.Broadcast{topic: "user:" <> @me, payload: ^expected}
    assert_receive %Phoenix.Socket.Broadcast{topic: "user:" <> @peer, payload: ^expected}
  end

  test "a NORMAL create emits nothing; an idempotent existing-direct (created:false) emits nothing" do
    Application.put_env(:api_gateway, :test_create_response, {
      :ok,
      %{conversation_id: @conv, created: true, secret: false, participant_user_ids: [@me, @peer]}
    })

    assert create().status == 201
    refute_receive {:system_message, _}, 50

    # An existing secret direct returned idempotently (created:false) must not re-emit.
    Application.put_env(:api_gateway, :test_create_response, {
      :ok,
      %{conversation_id: @conv, created: false, secret: true, participant_user_ids: [@me, @peer]}
    })

    assert create().status == 201
    refute_receive {:system_message, _}, 50
  end
end
