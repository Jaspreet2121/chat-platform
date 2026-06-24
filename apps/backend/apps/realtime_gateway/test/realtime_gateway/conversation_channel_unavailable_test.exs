defmodule RealtimeGateway.MessageUnavailableStub do
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
        :analytics_timeseries
      ] do
    @impl true
    def unquote(fun)(_attrs), do: {:error, :message_unavailable}
  end
end

defmodule RealtimeGateway.ConversationChannelUnavailableTest do
  @moduledoc """
  Plain (Docker-free, no network): a `message:create` over the channel is rejected with
  `realtime.unavailable` (not invalid_event) when the Message client is unreachable.
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
      RealtimeGateway.MessageUnavailableStub
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

  test "message:create → realtime.unavailable when message service is unreachable" do
    {:ok, _join, socket} =
      RealtimeGateway.UserSocket
      |> socket("user_socket:user_1", %{current_user_id: "user_1", device_id: "dev_1"})
      |> subscribe_and_join(RealtimeGateway.ConversationChannel, "conversation:conv_1", %{})

    ref = push(socket, "message:create", %{"message_type" => "text", "body" => "hi"})

    assert_reply ref, :error, reply
    assert reply.code == "realtime.unavailable"
  end
end
