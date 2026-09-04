defmodule RealtimeGateway.ConversationUpdatedFreshnessTest do
  @moduledoc """
  The SOCKET create path's `conversation_updated` frame must carry the timestamp of the message it was
  triggered by — not the one before it.

  THE DEFECT THIS LOCKS. `updated_at` on the wire comes from `conversations.last_message_at`, a
  denormalised column. Under the Scylla store (production) `ScyllaAdapter.put_message/1` only STAGES a
  Kafka event; the column is written later by the `InboxFromTopic` consumer. The fan-out fires the moment
  `create_message` returns, so it re-reads a row the projection has not reached and serialises the
  PREVIOUS message's stamp — one frame, one message behind, no corrected follow-up. Captured on hardware:
  a send at 11:58:01 produced a frame carrying 06:24:40.305Z, the message before it.

  `ConvStub.inbox_rows/1` reproduces that exactly: it ALWAYS answers @stale_row_at, standing in for the
  unprojected column. Any frame carrying that value is the bug.
  """
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  @endpoint RealtimeGateway.TestEndpoint

  @conversation "dm_1"
  @sender "u1"
  @peer "u2"

  # What the unprojected row still holds — the PREVIOUS message.
  @stale_row_at "2026-08-28T06:24:40.305000Z"
  # What the message we are about to send actually committed as.
  @committed_at "2026-08-28T06:28:01.117204Z"
  # …and what the unprojected row still says the preview is.
  @stale_preview "the PREVIOUS message"

  defmodule ConvStub do
    @moduledoc false
    def get_conversation(_attrs),
      do: {:ok, %{participants: [%{user_id: "u1"}, %{user_id: "u2"}]}}

    def authorize_send(_attrs), do: {:ok, %{authorized: true}}
    def direct_peer_blocked?(_attrs), do: {:ok, %{blocked: false}}

    # ALWAYS the stale value: the Kafka projection has not run yet. The fix must not depend on this
    # row ever advancing.
    def inbox_rows(%{"user_ids" => user_ids}) do
      rows =
        Enum.map(user_ids, fn user_id ->
          %{
            user_id: user_id,
            conversation_id: "dm_1",
            type: "direct",
            title: nil,
            last_message_preview: "the PREVIOUS message",
            last_message_kind: "text",
            unread_count: 0,
            updated_at: "2026-08-28T06:24:40.305000Z"
          }
        end)

      {:ok, %{rows: rows}}
    end
  end

  defmodule MsgStub do
    @moduledoc false
    # Echoes back a committed message stamped @committed_at — the post-write truth the frame must reflect.
    def create_message(attrs) do
      {:ok,
       %{
         message_id: "m-1",
         conversation_id: Map.get(attrs, "conversation_id"),
         sender_user_id: Map.get(attrs, "sender_user_id"),
         message_type: Map.get(attrs, "message_type"),
         body: Map.get(attrs, "body"),
         metadata: Map.get(attrs, "metadata") || %{},
         status: "active",
         created_at: "2026-08-28T06:28:01.117204Z"
       }}
    end
  end

  # SharedInfra.MediaAttachPolicy resolves media_id before the socket may attach it, so the media case
  # needs an asset owned by @sender.
  defmodule MediaStub do
    @moduledoc false
    def get_asset(%{"media_id" => "m-9"}),
      do: {:ok, %{media_id: "m-9", owner_user_id: "u1", status: "ready", purpose: "message"}}

    def get_asset(_attrs), do: {:error, :not_found}
  end

  setup do
    prev_media = Application.get_env(:shared_infra, :media_client_adapter)
    Application.put_env(:shared_infra, :media_client_adapter, MediaStub)
    prev_conv = Application.get_env(:shared_infra, :conversation_client_adapter)
    prev_msg = Application.get_env(:shared_infra, :message_client_adapter)
    prev_persist = Application.get_env(:conversation_service, :conversation_persistence)

    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :message_client_adapter, MsgStub)
    Application.put_env(:conversation_service, :conversation_persistence, false)

    on_exit(fn ->
      restore(:shared_infra, :media_client_adapter, prev_media)
      restore(:shared_infra, :conversation_client_adapter, prev_conv)
      restore(:shared_infra, :message_client_adapter, prev_msg)
      restore(:conversation_service, :conversation_persistence, prev_persist)
    end)

    :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp join_channel do
    {:ok, _reply, socket} =
      RealtimeGateway.UserSocket
      |> socket("user_socket:#{@sender}", %{current_user_id: @sender, user_id: @sender})
      |> subscribe_and_join(
        RealtimeGateway.ConversationChannel,
        "conversation:#{@conversation}",
        %{}
      )

    socket
  end

  # The fan-out runs in a Task and targets user:<id> topics, so subscribe to PubSub directly rather than
  # relying on the channel's own assert_broadcast.
  defp await_frame(user_id) do
    receive do
      %Phoenix.Socket.Broadcast{event: "conversation_updated", payload: payload} -> payload
    after
      1500 -> flunk("no conversation_updated frame for #{user_id}")
    end
  end

  defp send_message(socket, payload) do
    ref = push(socket, "message:create", payload)
    assert_reply(ref, :ok, _response, 1500)
    :ok
  end

  test "the frame carries the COMMITTED message's timestamp, not the unprojected row's" do
    Phoenix.PubSub.subscribe(RealtimeGateway.PubSub, "user:#{@peer}")
    socket = join_channel()

    send_message(socket, %{"message_type" => "text", "body" => "hello"})

    payload = await_frame(@peer)

    assert payload["updated_at"] == @committed_at
    refute payload["updated_at"] == @stale_row_at
  end

  test "the SENDER's own frame is fresh too — their list ordering broke the same way" do
    Phoenix.PubSub.subscribe(RealtimeGateway.PubSub, "user:#{@sender}")
    socket = join_channel()

    send_message(socket, %{"message_type" => "text", "body" => "hello"})

    assert await_frame(@sender)["updated_at"] == @committed_at
  end

  test "SEALED messages get the same treatment — the metadata differs, the timestamp must not" do
    Phoenix.PubSub.subscribe(RealtimeGateway.PubSub, "user:#{@peer}")
    socket = join_channel()

    send_message(socket, %{
      "message_type" => "sealed",
      "metadata" => %{"envelopes" => [%{"device_id" => "d1", "ciphertext" => "AA=="}]}
    })

    assert await_frame(@peer)["updated_at"] == @committed_at
  end

  test "the frame's PREVIEW and KIND come from the triggering message, not the unprojected row" do
    Phoenix.PubSub.subscribe(RealtimeGateway.PubSub, "user:#{@peer}")
    socket = join_channel()

    send_message(socket, %{"message_type" => "text", "body" => "the message that triggered this"})

    payload = await_frame(@peer)
    assert payload["last_message_preview"] == "the message that triggered this"
    assert payload["last_message_kind"] == "text"
    refute payload["last_message_preview"] == @stale_preview
  end

  test "MEDIA: no preview text, kind resolved from the message's own metadata.content_type" do
    Phoenix.PubSub.subscribe(RealtimeGateway.PubSub, "user:#{@peer}")
    socket = join_channel()

    send_message(socket, %{
      "message_type" => "media",
      "body" => "photo.png",
      "media_id" => "m-9",
      "metadata" => %{"content_type" => "image/png"}
    })

    payload = await_frame(@peer)
    assert payload["last_message_preview"] == nil
    assert payload["last_message_kind"] == "image"
  end

  test "108: a SEALED send puts NO content on the wire — kind only" do
    Phoenix.PubSub.subscribe(RealtimeGateway.PubSub, "user:#{@peer}")
    socket = join_channel()

    send_message(socket, %{
      "message_type" => "sealed",
      "metadata" => %{"envelopes" => [%{"device_id" => "d1", "ciphertext" => "AA=="}]}
    })

    payload = await_frame(@peer)
    assert payload["last_message_preview"] == nil
    assert payload["last_message_kind"] == "sealed"
    refute payload["last_message_preview"] == @stale_preview
  end
end
