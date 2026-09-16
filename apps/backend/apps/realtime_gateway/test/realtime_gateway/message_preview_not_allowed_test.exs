defmodule RealtimeGateway.MessagePreviewNotAllowedStub do
  @moduledoc false
  def create_message(_attrs), do: {:error, :preview_not_allowed}
end

defmodule RealtimeGateway.MessagePreviewNotAllowedTest do
  @moduledoc """
  The socket carries the same distinct code as REST for a sealed message with a plaintext preview
  (mirror of ApiGatewayWeb.MessagePreviewNotAllowedTest); without its own clause it would fall
  through to realtime.invalid_event.
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
      RealtimeGateway.MessagePreviewNotAllowedStub
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

  test "message:create of a sealed message with a preview → message.preview_not_allowed" do
    {:ok, _join, socket} =
      RealtimeGateway.UserSocket
      |> socket("user_socket:user_1", %{current_user_id: "user_1", device_id: "dev_1"})
      |> subscribe_and_join(RealtimeGateway.ConversationChannel, "conversation:conv_1", %{})

    ref =
      push(socket, "message:create", %{
        "message_type" => "text",
        "body" => "stub answers preview_not_allowed",
        "preview" => %{"inline_b64" => "AAAA", "w" => 1, "h" => 1}
      })

    assert_reply(ref, :error, reply)
    assert reply.code == "message.preview_not_allowed"
    refute_broadcast("message_created", _)
  end
end
