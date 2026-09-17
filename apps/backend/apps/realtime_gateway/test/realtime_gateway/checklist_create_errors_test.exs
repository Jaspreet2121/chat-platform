defmodule RealtimeGateway.ChecklistCreateErrorsStub do
  @moduledoc false
  def create_message(_attrs),
    do: {:error, Application.get_env(:realtime_gateway, :checklist_create_error)}
end

defmodule RealtimeGateway.ChecklistCreateErrorsTest do
  @moduledoc """
  The socket half of the same fix: a malformed checklist fell through to realtime.invalid_event —
  indistinguishable from a broken payload, so the client showed "something went wrong" instead of
  the reason. Mirrors ApiGatewayWeb.ChecklistCreateErrorsTest.
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
      RealtimeGateway.ChecklistCreateErrorsStub
    )

    on_exit(fn ->
      Application.put_env(:conversation_service, :conversation_persistence, prev_conv)
      Application.put_env(:realtime_gateway, :socket_auth_persistence, prev_auth)
      Application.delete_env(:realtime_gateway, :checklist_create_error)

      if prev_msg,
        do: Application.put_env(:shared_infra, :message_client_adapter, prev_msg),
        else: Application.delete_env(:shared_infra, :message_client_adapter)
    end)

    {:ok, _join, socket} =
      RealtimeGateway.UserSocket
      |> socket("user_socket:user_1", %{current_user_id: "user_1", device_id: "dev_1"})
      |> subscribe_and_join(RealtimeGateway.ConversationChannel, "conversation:conv_1", %{})

    {:ok, socket: socket}
  end

  test "each checklist failure carries its own code to the socket sender", %{socket: socket} do
    for {reason, expected} <- [
          {:checklist_not_in_sealed, "checklist.not_in_sealed"},
          {:checklist_too_many_items, "checklist.too_many_items"},
          {:checklist_text_too_long, "checklist.text_too_long"},
          {:checklist_no_items, "checklist.no_items"},
          {:checklist_invalid_item, "checklist.invalid_item"},
          {:checklist_invalid_title, "checklist.invalid_title"}
        ] do
      Application.put_env(:realtime_gateway, :checklist_create_error, reason)

      ref = push(socket, "message:create", %{"message_type" => "text", "body" => "x"})
      assert_reply(ref, :error, reply)

      assert reply.code == expected,
             "#{reason} gave #{inspect(reply.code)} — a client cannot tell it from a broken payload"
    end

    refute_broadcast("message_created", _)
  end

  test "an unrelated failure still falls to realtime.invalid_event", %{socket: socket} do
    Application.put_env(:realtime_gateway, :checklist_create_error, :message_invalid)

    ref = push(socket, "message:create", %{"message_type" => "text", "body" => "x"})
    assert_reply(ref, :error, reply)
    assert reply.code == "realtime.invalid_event"
  end
end
