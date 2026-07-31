defmodule RealtimeGateway.MessageDeletedStub do
  @moduledoc false
  # The service refuses ANY update to a soft-deleted message (body edit or live-location metadata patch).
  def update_message(_attrs), do: {:error, :message_deleted}

  for fun <- [
        :create_message,
        :send_message,
        :list_messages,
        :list_timeline,
        :edit_message,
        :delete_message,
        :mark_read,
        :mark_delivered,
        :analytics_overview,
        :analytics_timeseries,
        :admin_delete_message,
        :add_reaction,
        :remove_reaction,
        :star_message,
        :unstar_message,
        :list_starred,
        :search_messages,
        :get_by_media_id,
        :list_media
      ] do
    def unquote(fun)(_attrs), do: {:error, :message_unavailable}
  end
end

defmodule RealtimeGateway.MessageDeletedUpdateTest do
  @moduledoc """
  The socket's `message:update` (and the live-location `:metadata` patch, which shares the same author gate)
  must REJECT a soft-deleted message rather than resurrect it — with an error reply that keeps the socket
  alive, like every other rejected event.
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
      RealtimeGateway.MessageDeletedStub
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

  defp joined do
    {:ok, _join, socket} =
      RealtimeGateway.UserSocket
      |> socket("user_socket:user_1", %{
        current_user_id: "user_1",
        user_id: "user_1",
        device_id: "d1"
      })
      |> subscribe_and_join(RealtimeGateway.ConversationChannel, "conversation:conv_1", %{})

    socket
  end

  test "message:update on a soft-deleted message → realtime.message_deleted; socket stays alive" do
    socket = joined()

    ref =
      push(socket, "message:update", %{"message_id" => "msg_1", "body" => "back from the dead"})

    assert_reply ref, :error, reply
    assert reply.code == "realtime.message_deleted"

    # The channel is still usable — a rejected update must never take the socket down.
    typing_ref = push(socket, "typing:start", %{})
    assert_reply typing_ref, :ok, _typing
  end

  test "live_location:update on a soft-deleted message is refused too (same author gate)" do
    socket = joined()

    ref =
      push(socket, "live_location:update", %{
        "message_id" => "msg_1",
        "lat" => 1.0,
        "lng" => 2.0
      })

    assert_reply ref, :error, reply
    assert reply.code == "realtime.message_deleted"
  end
end
