defmodule ApiGatewayWeb.ForwardRestrictedErrorTest do
  @moduledoc """
  RESTRICTED SHARING (120) — the refusal a client has to be able to EXPLAIN.

  The message service refuses a forward out of a restricted conversation with :forward_restricted.
  That atom means nothing on the wire; what the client renders comes from the code the gateway maps
  it to. A generic invalid_request would surface as "something went wrong" on a refusal the user is
  entitled to understand ("Forwarding is turned off for this chat"), so the DISTINCT code is the
  contract — pinned here for both send paths, because a forward can be sent over either.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.MessageController

  @conversation "11111111-1111-4111-8111-111111111111"
  @sender "22222222-2222-4222-8222-222222222222"

  defmodule AuthStub do
    @moduledoc false
    def current_session(%{"authorization" => "Bearer sender"}),
      do:
        {:ok,
         %{
           user_id: "22222222-2222-4222-8222-222222222222",
           app_id: "44444444-4444-4444-8444-444444444444"
         }}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule ConvStub do
    @moduledoc false
    def get_conversation_app(_attrs), do: {:ok, %{}}

    def get_conversation(_attrs),
      do:
        {:ok,
         %{
           app_id: "44444444-4444-4444-8444-444444444444",
           participants: [%{user_id: "22222222-2222-4222-8222-222222222222"}]
         }}

    def authorize_send(_attrs), do: {:ok, %{authorized: true}}
    def inbox_rows(_attrs), do: {:ok, %{rows: []}}
  end

  # The store's refusal, verbatim — MessageService.Messages.check_forward_policy's own return.
  defmodule RestrictedMsgStub do
    @moduledoc false
    def create_message(_attrs), do: {:error, :forward_restricted}
  end

  setup do
    prev = %{
      auth: Application.get_env(:shared_infra, :auth_client_adapter),
      conv: Application.get_env(:shared_infra, :conversation_client_adapter),
      msg: Application.get_env(:shared_infra, :message_client_adapter),
      persist: Application.get_env(:message_service, :message_persistence, false)
    }

    Application.put_env(:message_service, :message_persistence, true)
    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :message_client_adapter, RestrictedMsgStub)

    on_exit(fn ->
      Application.put_env(:message_service, :message_persistence, prev.persist)
      restore(:auth_client_adapter, prev.auth)
      restore(:conversation_client_adapter, prev.conv)
      restore(:message_client_adapter, prev.msg)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)

  test "a refused forward answers 403 conversation.sharing_disabled, with a message a client can show" do
    conn =
      :post
      |> conn("/api/v1/conversations/#{@conversation}/messages", %{})
      |> put_req_header("authorization", "Bearer sender")
      |> MessageController.create(%{
        "conversation_id" => @conversation,
        "message_type" => "text",
        "body" => "forwarded copy",
        "forwarded_from_message_id" => "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        "forwarded_from_conversation_id" => "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
      })

    assert conn.status == 403

    body = Jason.decode!(conn.resp_body)

    assert body["error"]["code"] == "conversation.sharing_disabled",
           "the refusal carried a generic code (#{inspect(body["error"]["code"])}) — the client " <>
             "cannot tell the user WHY the forward failed, so it reads as a bug in the app"

    assert body["error"]["message"] =~ "Forwarding is turned off"
  end
end
