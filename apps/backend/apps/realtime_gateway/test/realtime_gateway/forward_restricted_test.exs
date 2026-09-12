defmodule RealtimeGateway.ForwardRestrictedStub do
  @moduledoc false
  # Every create is a restricted forward; nothing else is exercised here.
  def create_message(_attrs), do: {:error, :forward_restricted}
end

defmodule RealtimeGateway.ForwardRestrictedTest do
  @moduledoc """
  RESTRICTED SHARING (120) over the SOCKET.

  A forward can be sent on either path, so the socket must carry the same distinct code the REST
  create does (ApiGatewayWeb.ForwardRestrictedErrorTest pins that half). Without its own clause the
  refusal falls through to `realtime.invalid_event` — indistinguishable from a malformed payload, so
  the client shows "something went wrong" instead of "forwarding is turned off for this chat".
  """
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  @endpoint RealtimeGateway.TestEndpoint

  setup do
    prev_conv = Application.get_env(:conversation_service, :conversation_persistence, false)
    prev_auth = Application.get_env(:realtime_gateway, :socket_auth_persistence, false)
    prev_msg = Application.get_env(:shared_infra, :message_client_adapter)

    Application.put_env(:conversation_service, :conversation_persistence, false)
    Application.put_env(:realtime_gateway, :socket_auth_persistence, false)

    Application.put_env(
      :shared_infra,
      :message_client_adapter,
      RealtimeGateway.ForwardRestrictedStub
    )

    on_exit(fn ->
      Application.put_env(:conversation_service, :conversation_persistence, prev_conv)
      Application.put_env(:realtime_gateway, :socket_auth_persistence, prev_auth)

      if prev_msg,
        do: Application.put_env(:shared_infra, :message_client_adapter, prev_msg),
        else: Application.delete_env(:shared_infra, :message_client_adapter)
    end)

    :ok
  end

  test "message:create of a restricted forward → conversation.sharing_disabled, not invalid_event" do
    {:ok, _join, socket} =
      RealtimeGateway.UserSocket
      |> socket("user_socket:user_1", %{current_user_id: "user_1", device_id: "dev_1"})
      |> subscribe_and_join(RealtimeGateway.ConversationChannel, "conversation:conv_1", %{})

    ref =
      push(socket, "message:create", %{
        "message_type" => "text",
        "body" => "forwarded copy",
        "forwarded_from_message_id" => "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        "forwarded_from_conversation_id" => "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
      })

    assert_reply(ref, :error, reply)

    assert reply.code == "conversation.sharing_disabled",
           "the socket refusal carried #{inspect(reply.code)} — a client cannot tell a restricted " <>
             "forward from a malformed payload, so it reads as a bug in the app"

    assert reply.message =~ "Forwarding is turned off"

    # Nothing was fanned out: a refused forward never reaches the other members.
    refute_broadcast("message_created", _)
  end
end
