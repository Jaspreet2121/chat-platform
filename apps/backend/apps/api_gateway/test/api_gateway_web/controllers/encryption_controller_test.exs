defmodule ApiGatewayWeb.EncryptionControllerTest do
  @moduledoc """
  The secret-chat toggle's gateway half (108), no DB: enabling writes the PLAINTEXT system message
  {kind: encryption, state: enabled} through the normal message path, fans it out on the
  conversation topic, and broadcasts conversation_encryption_changed to BOTH members; an
  already-secret re-enable stays silent; the 409 names the keyless side; and the keys_changed
  emission (SecretChatEvents) writes one system message per secret conversation on a key change
  and on a device revoke — never breaking the operation that triggered it.
  """
  use ExUnit.Case, async: false

  import Plug.Test

  alias ApiGatewayWeb.EncryptionController
  alias ApiGatewayWeb.SecretChatEvents

  @me "11111111-1111-1111-1111-111111111111"
  @peer "22222222-2222-2222-2222-222222222222"
  @conv "33333333-3333-3333-3333-333333333333"

  defmodule AuthStub do
    def current_session(%{"authorization" => "Bearer token"}),
      do:
        {:ok,
         %{
           user_id: "11111111-1111-1111-1111-111111111111",
           app_id: "44444444-4444-4444-8444-444444444444"
         }}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule ConversationStub do
    def set_encryption(attrs) do
      send(:enc_test, {:set_encryption, attrs})

      Application.get_env(
        :api_gateway,
        :test_set_encryption,
        {:ok,
         %{
           enabled: true,
           already: false,
           member_ids: [
             "11111111-1111-1111-1111-111111111111",
             "22222222-2222-2222-2222-222222222222"
           ]
         }}
      )
    end

    def secret_conversations_of(_attrs) do
      {:ok,
       %{
         conversation_ids: Application.get_env(:api_gateway, :test_secret_convs, [])
       }}
    end
  end

  defmodule MessageStub do
    def create_message(attrs) do
      send(:enc_test, {:system_message, attrs})
      {:ok, Map.put(attrs, "message_id", "sys-1")}
    end
  end

  setup do
    Process.register(self(), :enc_test)

    keys = [
      auth_client_adapter: AuthStub,
      conversation_client_adapter: ConversationStub,
      message_client_adapter: MessageStub
    ]

    previous = for {key, _} <- keys, into: %{}, do: {key, Application.get_env(:shared_infra, key)}
    for {key, value} <- keys, do: Application.put_env(:shared_infra, key, value)

    on_exit(fn ->
      for {key, value} <- previous do
        if value,
          do: Application.put_env(:shared_infra, key, value),
          else: Application.delete_env(:shared_infra, key)
      end

      for key <- [:test_set_encryption, :test_secret_convs],
          do: Application.delete_env(:api_gateway, key)
    end)
  end

  defp toggle(params) do
    :post
    |> conn("/api/v1/conversations/#{@conv}/encryption", params)
    |> Plug.Conn.put_req_header("authorization", "Bearer token")
    |> EncryptionController.update(Map.put(params, "conversation_id", @conv))
  end

  test "ENABLE: system message via the normal path + conversation fan-out + both members notified" do
    ApiGatewayWeb.Endpoint.subscribe("user:" <> @me)
    ApiGatewayWeb.Endpoint.subscribe("user:" <> @peer)
    ApiGatewayWeb.Endpoint.subscribe("conversation:" <> @conv)

    conn = toggle(%{"enabled" => true})
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"enabled" => true}

    assert_receive {:set_encryption, attrs}
    assert attrs["user_id"] == @me
    assert attrs["enabled"] == true

    # The plaintext SYSTEM message (protocol state, no user content) through the message path.
    assert_receive {:system_message, message}
    assert message["message_type"] == "system"
    assert message["metadata"] == %{"kind" => "encryption", "state" => "enabled", "by" => @me}

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "conversation:" <> @conv,
      event: "message_created"
    }

    expected = %{
      "type" => "conversation_encryption_changed",
      "conversation_id" => @conv,
      "enabled" => true
    }

    assert_receive %Phoenix.Socket.Broadcast{topic: "user:" <> @me, payload: ^expected}
    assert_receive %Phoenix.Socket.Broadcast{topic: "user:" <> @peer, payload: ^expected}
  end

  test "ALREADY secret: idempotent 200, NO new system message; errors map with the keyless side" do
    Application.put_env(
      :api_gateway,
      :test_set_encryption,
      {:ok, %{enabled: true, already: true, member_ids: [@me, @peer]}}
    )

    conn = toggle(%{"enabled" => true})
    assert conn.status == 200
    refute_receive {:system_message, _}, 50

    for {error, status, code} <- [
          {{:error, :secret_not_supported}, 422, "secret.not_supported"},
          {{:error, :secret_cannot_disable}, 422, "secret.cannot_disable"},
          {{:error, :conversation_not_found}, 404, "conversation.not_found"}
        ] do
      Application.put_env(:api_gateway, :test_set_encryption, error)
      conn = toggle(%{"enabled" => true})
      assert conn.status == status
      assert %{"error" => %{"code" => ^code}} = Jason.decode!(conn.resp_body)
    end

    Application.put_env(
      :api_gateway,
      :test_set_encryption,
      {:error, {:secret_peer_keys_missing, [@peer]}}
    )

    conn = toggle(%{"enabled" => true})
    assert conn.status == 409
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "secret.peer_keys_missing"
    # WHICH side is missing — the client prompts the right person.
    assert body["error"]["missing_user_ids"] == [@peer]
  end

  test "KEYS_CHANGED: one system message per secret conversation; empty set is silent; never raises" do
    Application.put_env(:api_gateway, :test_secret_convs, [
      @conv,
      "77777777-7777-4777-8777-777777777777"
    ])

    assert :ok = SecretChatEvents.emit_keys_changed(@me)

    assert_receive {:system_message, first}
    assert_receive {:system_message, second}
    refute_receive {:system_message, _}, 50

    for message <- [first, second] do
      assert message["message_type"] == "system"

      assert message["metadata"] == %{
               "kind" => "encryption",
               "state" => "keys_changed",
               "user" => @me
             }
    end

    # No secret conversations → nothing written.
    Application.put_env(:api_gateway, :test_secret_convs, [])
    assert :ok = SecretChatEvents.emit_keys_changed(@me)
    refute_receive {:system_message, _}, 50

    # A broken seam never raises out (the triggering operation already succeeded).
    Application.put_env(:shared_infra, :conversation_client_adapter, __MODULE__.Broken)
    assert :ok = SecretChatEvents.emit_keys_changed(@me)
  end

  defmodule Broken do
    def secret_conversations_of(_), do: raise("seam down")
  end
end
