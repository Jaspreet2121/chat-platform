defmodule RealtimeGateway.ChannelsTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  alias MessageService.MessageStore

  @endpoint RealtimeGateway.TestEndpoint

  # SharedInfra.MediaAttachPolicy now resolves a media_id before the socket may attach it, so the two
  # media-message cases below need an asset owned by the socket's user. Before the policy the id rode
  # through unresolved — the same hole the REST path had.
  defmodule MediaStub do
    @moduledoc false
    def get_asset(%{"media_id" => "44444444-4444-4444-8444-444444444444"}),
      do:
        {:ok,
         %{
           media_id: "44444444-4444-4444-8444-444444444444",
           owner_user_id: "user_123",
           status: "ready",
           purpose: "message"
         }}

    def get_asset(_attrs), do: {:error, :not_found}
  end

  setup do
    previous_media_adapter = Application.get_env(:shared_infra, :media_client_adapter)
    Application.put_env(:shared_infra, :media_client_adapter, MediaStub)

    previous_conversation_persistence =
      Application.get_env(:conversation_service, :conversation_persistence, false)

    previous_socket_auth =
      Application.get_env(:realtime_gateway, :socket_auth_persistence, false)

    previous_message_persistence =
      Application.get_env(:message_service, :message_persistence, false)

    previous_message_adapter =
      Application.get_env(:message_service, :message_store_adapter, MessageStore.QueryPlanAdapter)

    previous_session_persistence =
      Application.get_env(:auth_service, :session_persistence, false)

    Application.put_env(:conversation_service, :conversation_persistence, false)
    Application.put_env(:realtime_gateway, :socket_auth_persistence, false)
    Application.put_env(:message_service, :message_persistence, false)
    Application.put_env(:message_service, :message_store_adapter, previous_message_adapter)

    on_exit(fn ->
      if previous_media_adapter,
        do: Application.put_env(:shared_infra, :media_client_adapter, previous_media_adapter),
        else: Application.delete_env(:shared_infra, :media_client_adapter)

      Application.put_env(:auth_service, :session_persistence, previous_session_persistence)

      Application.put_env(
        :conversation_service,
        :conversation_persistence,
        previous_conversation_persistence
      )

      Application.put_env(:realtime_gateway, :socket_auth_persistence, previous_socket_auth)
      Application.put_env(:message_service, :message_persistence, previous_message_persistence)
      Application.put_env(:message_service, :message_store_adapter, previous_message_adapter)

      if Process.whereis(MessageStore.InMemoryAdapter) do
        MessageStore.InMemoryAdapter.reset()
      end
    end)

    :ok
  end

  test "socket connect preserves placeholder auth when persistence is disabled" do
    assert {:ok, socket} = connect(RealtimeGateway.UserSocket, %{})

    assert socket.assigns.current_user_id == "user_placeholder"
    assert socket.assigns.user_id == "user_placeholder"
    assert socket.assigns.device_id == "device_placeholder"
  end

  test "socket connect rejects missing token when realtime auth persistence is enabled" do
    Application.put_env(:realtime_gateway, :socket_auth_persistence, true)

    assert :error = connect(RealtimeGateway.UserSocket, %{})
  end

  test "fails closed when socket auth is on but the session layer is not DB-backed" do
    # Foot-gun regression: REALTIME_AUTH_DB_BACKED on while AUTH_SESSION_DB_BACKED off
    # must NOT accept the unverified placeholder identity. Docker-free (rejected before
    # any session lookup).
    Application.put_env(:realtime_gateway, :socket_auth_persistence, true)
    Application.put_env(:auth_service, :session_persistence, false)

    assert :error =
             connect(RealtimeGateway.UserSocket, %{"authorization" => "Bearer any.token.value"})
  end

  @tag :postgres_integration
  test "accepts a valid DB-backed session token and assigns the real verified user" do
    {:ok, _pid} = start_auth_repo!()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(AuthService.Repo)

    Application.put_env(:realtime_gateway, :socket_auth_persistence, true)
    Application.put_env(:auth_service, :session_persistence, true)

    user_id = Ecto.UUID.generate()
    session_id = Ecto.UUID.generate()
    device_id = "socket-device-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now()

    {1, _} =
      AuthService.Repo.insert_all(AuthService.Schemas.UserAuth, [
        %{
          id: user_id,
          phone_number: "+1555#{System.unique_integer([:positive])}",
          status: "active",
          created_at: now,
          updated_at: now
        }
      ])

    {1, _} =
      AuthService.Repo.insert_all(AuthService.Schemas.DeviceSession, [
        %{
          id: session_id,
          user_id: user_id,
          device_id: device_id,
          platform: "ios",
          refresh_token_hash: "sha256:test-socket-session",
          created_at: now
        }
      ])

    {:ok, %{access_token: access_token}} =
      AuthService.Tokens.prepare_issue_pair(%{
        "user_id" => user_id,
        "device_id" => device_id,
        "session_id" => session_id
      })

    assert {:ok, socket} =
             connect(RealtimeGateway.UserSocket, %{"authorization" => "Bearer #{access_token}"})

    assert socket.assigns.current_user_id == user_id
    assert socket.assigns.current_user_id != "user_placeholder"
    assert socket.assigns.device_id == device_id
  end

  @tag :postgres_integration
  test "rejects a tampered token even when the session layer is DB-backed" do
    {:ok, _pid} = start_auth_repo!()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(AuthService.Repo)

    Application.put_env(:realtime_gateway, :socket_auth_persistence, true)
    Application.put_env(:auth_service, :session_persistence, true)

    assert :error =
             connect(RealtimeGateway.UserSocket, %{
               "authorization" => "Bearer v1.tampered.signature"
             })
  end

  test "joins conversation topic and handles typing events" do
    {:ok, join_reply, socket} =
      RealtimeGateway.UserSocket
      |> socket("user_socket:user_123", %{current_user_id: "user_123", device_id: "dev_123"})
      |> subscribe_and_join(RealtimeGateway.ConversationChannel, "conversation:conv_123", %{})

    assert join_reply.status == "joined"
    assert join_reply.conversation_id == "conv_123"

    ref = push(socket, "typing_started", %{"source" => "test"})

    assert_reply ref, :ok, reply
    assert reply.event == "typing_started"
    assert reply.status == "accepted"
    assert reply.conversation_id == "conv_123"
  end

  test "presence tracking pushes state after conversation join when user_id exists" do
    {:ok, join_reply, _socket} =
      RealtimeGateway.UserSocket
      |> socket("user_socket:presence_user", %{
        current_user_id: "presence_user",
        user_id: "presence_user",
        device_id: "dev_123"
      })
      |> subscribe_and_join(
        RealtimeGateway.ConversationChannel,
        "conversation:presence_conv",
        %{}
      )

    assert join_reply.status == "joined"

    assert_push "presence_state", presence_state
    assert %{"presence_user" => %{metas: [meta | _]}} = presence_state
    assert meta.user_id == "presence_user"
    assert is_binary(meta.online_at)
  end

  test "typing:start broadcasts typing_started payload" do
    {:ok, _join_reply, socket} =
      RealtimeGateway.UserSocket
      |> socket("user_socket:typing_user", %{
        current_user_id: "typing_user",
        user_id: "typing_user",
        device_id: "dev_123"
      })
      |> subscribe_and_join(RealtimeGateway.ConversationChannel, "conversation:typing_conv", %{})

    ref = push(socket, "typing:start", %{})

    assert_reply ref, :ok, reply
    assert reply.event == "typing_started"
    assert reply.conversation_id == "typing_conv"
    assert reply.user_id == "typing_user"
    assert is_binary(reply.occurred_at)

    assert_broadcast "typing_started", broadcast
    assert broadcast.conversation_id == "typing_conv"
    assert broadcast.user_id == "typing_user"
  end

  test "typing:stop broadcasts typing_stopped payload" do
    {:ok, _join_reply, socket} =
      RealtimeGateway.UserSocket
      |> socket("user_socket:typing_user", %{
        current_user_id: "typing_user",
        user_id: "typing_user",
        device_id: "dev_123"
      })
      |> subscribe_and_join(RealtimeGateway.ConversationChannel, "conversation:typing_conv", %{})

    ref = push(socket, "typing:stop", %{})

    assert_reply ref, :ok, reply
    assert reply.event == "typing_stopped"
    assert reply.conversation_id == "typing_conv"
    assert reply.user_id == "typing_user"
    assert is_binary(reply.occurred_at)

    assert_broadcast "typing_stopped", broadcast
    assert broadcast.conversation_id == "typing_conv"
    assert broadcast.user_id == "typing_user"
  end

  test "typing events reject safely when socket user is missing" do
    {:ok, _join_reply, socket} =
      RealtimeGateway.UserSocket
      |> socket("user_socket:missing", %{current_user_id: nil, device_id: "dev_123"})
      |> subscribe_and_join(RealtimeGateway.ConversationChannel, "conversation:typing_conv", %{})

    ref = push(socket, "typing:start", %{})

    assert_reply ref, :error, reply
    assert reply.code == "realtime.unauthorized"
  end

  test "DB-aware conversation join rejects missing socket user" do
    Application.put_env(:conversation_service, :conversation_persistence, true)

    assert {:error, reply} =
             RealtimeGateway.UserSocket
             |> socket("user_socket:missing", %{})
             |> subscribe_and_join(
               RealtimeGateway.ConversationChannel,
               "conversation:conv_123",
               %{}
             )

    assert reply.code == "realtime.unauthorized"
  end

  test "DB-aware conversation join rejects invalid conversation before persistence lookup" do
    Application.put_env(:conversation_service, :conversation_persistence, true)

    assert {:error, reply} =
             RealtimeGateway.UserSocket
             |> socket("user_socket:user_123", %{
               current_user_id: "user_123",
               device_id: "dev_123"
             })
             |> subscribe_and_join(RealtimeGateway.ConversationChannel, "conversation:", %{})

    assert reply.code == "realtime.forbidden"
  end

  test "creates a message event through the in-memory message adapter" do
    Application.put_env(:message_service, :message_persistence, true)
    Application.put_env(:message_service, :message_store_adapter, MessageStore.InMemoryAdapter)
    start_in_memory_store!()
    MessageStore.InMemoryAdapter.reset()

    {:ok, _join_reply, socket} =
      RealtimeGateway.UserSocket
      |> socket("user_socket:user_123", %{current_user_id: "user_123", device_id: "dev_123"})
      |> subscribe_and_join(RealtimeGateway.ConversationChannel, "conversation:conv_123", %{})

    ref = push(socket, "message:create", %{"message_type" => "text", "body" => "Hello realtime"})

    assert_reply ref, :ok, reply
    assert reply.conversation_id == "conv_123"
    assert reply.sender_user_id == "user_123"
    assert reply.message_type == "text"
    assert reply.body == "Hello realtime"
    assert reply.status == "active"
  end

  test "creates a media message event through the in-memory message adapter" do
    Application.put_env(:message_service, :message_persistence, true)
    Application.put_env(:message_service, :message_store_adapter, MessageStore.InMemoryAdapter)
    start_in_memory_store!()
    MessageStore.InMemoryAdapter.reset()

    {:ok, _join_reply, socket} =
      RealtimeGateway.UserSocket
      |> socket("user_socket:user_123", %{current_user_id: "user_123", device_id: "dev_123"})
      |> subscribe_and_join(RealtimeGateway.ConversationChannel, "conversation:conv_123", %{})

    ref =
      push(socket, "message:create", %{
        "message_type" => "media",
        "media_id" => "44444444-4444-4444-8444-444444444444",
        "caption" => "Realtime photo"
      })

    assert_reply ref, :ok, reply
    assert reply.conversation_id == "conv_123"
    assert reply.sender_user_id == "user_123"
    assert reply.message_type == "media"
    assert reply.media_id == "44444444-4444-4444-8444-444444444444"
    assert reply.caption == "Realtime photo"
    assert reply.body == "Realtime photo"

    assert reply.metadata == %{
             "media_id" => "44444444-4444-4444-8444-444444444444",
             "caption" => "Realtime photo"
           }
  end

  test "media message event carries object_key metadata so other clients can open media" do
    Application.put_env(:message_service, :message_persistence, true)
    Application.put_env(:message_service, :message_store_adapter, MessageStore.InMemoryAdapter)
    start_in_memory_store!()
    MessageStore.InMemoryAdapter.reset()

    {:ok, _join_reply, socket} =
      RealtimeGateway.UserSocket
      |> socket("user_socket:user_123", %{current_user_id: "user_123", device_id: "dev_123"})
      |> subscribe_and_join(RealtimeGateway.ConversationChannel, "conversation:conv_123", %{})

    ref =
      push(socket, "message:create", %{
        "message_type" => "media",
        "media_id" => "44444444-4444-4444-8444-444444444444",
        "caption" => "Realtime photo",
        "metadata" => %{
          "object_key" => "media/user_123/44444444-4444-4444-8444-444444444444/photo.png",
          "filename" => "photo.png",
          "content_type" => "image/png",
          "size_bytes" => 1024
        }
      })

    assert_reply ref, :ok, reply
    assert reply.message_type == "media"

    assert reply.metadata["object_key"] ==
             "media/user_123/44444444-4444-4444-8444-444444444444/photo.png"

    assert reply.metadata["filename"] == "photo.png"
    assert reply.metadata["content_type"] == "image/png"
    assert reply.metadata["size_bytes"] == "1024"
    assert reply.metadata["media_id"] == "44444444-4444-4444-8444-444444444444"
    assert reply.metadata["caption"] == "Realtime photo"

    assert_broadcast "message_created", broadcast

    assert broadcast.metadata["object_key"] ==
             "media/user_123/44444444-4444-4444-8444-444444444444/photo.png"
  end

  test "message:update broadcasts message_updated to other clients" do
    Application.put_env(:message_service, :message_persistence, true)
    Application.put_env(:message_service, :message_store_adapter, MessageStore.InMemoryAdapter)
    start_in_memory_store!()
    MessageStore.InMemoryAdapter.reset()

    {:ok, _join_reply, socket} =
      RealtimeGateway.UserSocket
      |> socket("user_socket:user_123", %{current_user_id: "user_123", device_id: "dev_123"})
      |> subscribe_and_join(RealtimeGateway.ConversationChannel, "conversation:conv_123", %{})

    create_ref = push(socket, "message:create", %{"message_type" => "text", "body" => "Original"})
    assert_reply create_ref, :ok, created

    update_ref =
      push(socket, "message:update", %{
        "message_id" => created.message_id,
        "body" => "Edited body"
      })

    assert_reply update_ref, :ok, updated
    assert updated.message_id == created.message_id
    assert updated.body == "Edited body"
    assert updated.status == "edited"

    assert_broadcast "message_updated", broadcast
    assert broadcast.conversation_id == "conv_123"
    assert broadcast.message_id == created.message_id
    assert broadcast.body == "Edited body"
    assert broadcast.status == "edited"
  end

  test "message:delete broadcasts message_deleted to other clients" do
    Application.put_env(:message_service, :message_persistence, true)
    Application.put_env(:message_service, :message_store_adapter, MessageStore.InMemoryAdapter)
    start_in_memory_store!()
    MessageStore.InMemoryAdapter.reset()

    {:ok, _join_reply, socket} =
      RealtimeGateway.UserSocket
      |> socket("user_socket:user_123", %{current_user_id: "user_123", device_id: "dev_123"})
      |> subscribe_and_join(RealtimeGateway.ConversationChannel, "conversation:conv_123", %{})

    create_ref = push(socket, "message:create", %{"message_type" => "text", "body" => "Original"})
    assert_reply create_ref, :ok, created

    delete_ref = push(socket, "message:delete", %{"message_id" => created.message_id})

    assert_reply delete_ref, :ok, deleted
    assert deleted.message_id == created.message_id
    assert deleted.status == "deleted"

    assert_broadcast "message_deleted", broadcast
    assert broadcast.conversation_id == "conv_123"
    assert broadcast.message_id == created.message_id
    assert broadcast.status == "deleted"
  end

  test "reaction:set persists and broadcasts reaction_updated to other clients" do
    Application.put_env(:message_service, :message_persistence, true)
    Application.put_env(:message_service, :message_store_adapter, MessageStore.InMemoryAdapter)
    start_in_memory_store!()
    MessageStore.InMemoryAdapter.reset()

    {:ok, _join_reply, socket} =
      RealtimeGateway.UserSocket
      |> socket("user_socket:user_123", %{current_user_id: "user_123", device_id: "dev_123"})
      |> subscribe_and_join(RealtimeGateway.ConversationChannel, "conversation:conv_123", %{})

    create_ref = push(socket, "message:create", %{"message_type" => "text", "body" => "React me"})
    assert_reply create_ref, :ok, created

    set_ref =
      push(socket, "reaction:set", %{"message_id" => created.message_id, "emoji" => "👍"})

    assert_reply set_ref, :ok, reply
    assert reply.message_id == created.message_id
    assert reply.reactions == [%{emoji: "👍", count: 1}]

    assert_broadcast "reaction_updated", broadcast
    assert broadcast.message_id == created.message_id
    assert broadcast.reactions == [%{emoji: "👍", count: 1}]
  end

  test "reaction:remove broadcasts the cleared aggregate" do
    Application.put_env(:message_service, :message_persistence, true)
    Application.put_env(:message_service, :message_store_adapter, MessageStore.InMemoryAdapter)
    start_in_memory_store!()
    MessageStore.InMemoryAdapter.reset()

    {:ok, _join_reply, socket} =
      RealtimeGateway.UserSocket
      |> socket("user_socket:user_123", %{current_user_id: "user_123", device_id: "dev_123"})
      |> subscribe_and_join(RealtimeGateway.ConversationChannel, "conversation:conv_123", %{})

    create_ref = push(socket, "message:create", %{"message_type" => "text", "body" => "React me"})
    assert_reply create_ref, :ok, created

    set_ref =
      push(socket, "reaction:set", %{"message_id" => created.message_id, "emoji" => "❤️"})

    assert_reply set_ref, :ok, _set
    assert_broadcast "reaction_updated", _first

    remove_ref = push(socket, "reaction:remove", %{"message_id" => created.message_id})
    assert_reply remove_ref, :ok, reply
    assert reply.reactions == []

    assert_broadcast "reaction_updated", broadcast
    assert broadcast.message_id == created.message_id
    assert broadcast.reactions == []
  end

  test "rejects invalid reaction:set event without emoji" do
    {:ok, _join_reply, socket} =
      RealtimeGateway.UserSocket
      |> socket("user_socket:user_123", %{current_user_id: "user_123", device_id: "dev_123"})
      |> subscribe_and_join(RealtimeGateway.ConversationChannel, "conversation:conv_123", %{})

    ref = push(socket, "reaction:set", %{"message_id" => "msg_123"})

    assert_reply ref, :error, reply
    assert reply.code == "realtime.invalid_event"
  end

  test "rejects invalid message:update event without body" do
    {:ok, _join_reply, socket} =
      RealtimeGateway.UserSocket
      |> socket("user_socket:user_123", %{current_user_id: "user_123", device_id: "dev_123"})
      |> subscribe_and_join(RealtimeGateway.ConversationChannel, "conversation:conv_123", %{})

    ref = push(socket, "message:update", %{"message_id" => "msg_123"})

    assert_reply ref, :error, reply
    assert reply.code == "realtime.invalid_event"
  end

  test "message:update by a non-author is rejected with realtime.forbidden" do
    Application.put_env(:message_service, :message_persistence, true)
    Application.put_env(:message_service, :message_store_adapter, MessageStore.InMemoryAdapter)
    start_in_memory_store!()
    MessageStore.InMemoryAdapter.reset()

    bucket_date = Date.utc_today() |> Date.to_iso8601()

    {:ok, _seeded} =
      MessageStore.put_message(%{
        "conversation_id" => "conv_123",
        "bucket_date" => bucket_date,
        "message_id" => "seed-msg-author",
        "sender_user_id" => "other_user",
        "message_type" => "text",
        "body" => "Owned by other_user",
        "status" => "active",
        "created_at" => DateTime.utc_now()
      })

    {:ok, _join_reply, socket} =
      RealtimeGateway.UserSocket
      |> socket("user_socket:user_123", %{current_user_id: "user_123", device_id: "dev_123"})
      |> subscribe_and_join(RealtimeGateway.ConversationChannel, "conversation:conv_123", %{})

    ref =
      push(socket, "message:update", %{"message_id" => "seed-msg-author", "body" => "Hijacked"})

    assert_reply ref, :error, reply
    assert reply.code == "realtime.forbidden"
  end

  test "rejects invalid message create event payload" do
    {:ok, _join_reply, socket} =
      RealtimeGateway.UserSocket
      |> socket("user_socket:user_123", %{current_user_id: "user_123", device_id: "dev_123"})
      |> subscribe_and_join(RealtimeGateway.ConversationChannel, "conversation:conv_123", %{})

    ref = push(socket, "message:create", %{"message_type" => "text"})

    assert_reply ref, :error, reply
    assert reply.code == "realtime.invalid_event"
  end

  test "rejects media message event without media_id" do
    {:ok, _join_reply, socket} =
      RealtimeGateway.UserSocket
      |> socket("user_socket:user_123", %{current_user_id: "user_123", device_id: "dev_123"})
      |> subscribe_and_join(RealtimeGateway.ConversationChannel, "conversation:conv_123", %{})

    ref = push(socket, "message:create", %{"message_type" => "media", "caption" => "No id"})

    assert_reply ref, :error, reply
    assert reply.code == "realtime.invalid_event"
  end

  test "handles message receipt client events on conversation topic" do
    {:ok, _join_reply, socket} =
      RealtimeGateway.UserSocket
      |> socket("user_socket:user_123", %{current_user_id: "user_123", device_id: "dev_123"})
      |> subscribe_and_join(RealtimeGateway.ConversationChannel, "conversation:conv_123", %{})

    read_ref = push(socket, "message_read", %{"message_id" => "msg_123"})
    delivered_ref = push(socket, "message_delivered", %{"message_id" => "msg_123"})

    assert_reply read_ref, :ok, read_reply
    assert read_reply.event == "message_read"
    assert read_reply.status == "accepted"

    assert_reply delivered_ref, :ok, delivered_reply
    assert delivered_reply.event == "message_delivered"
    assert delivered_reply.status == "accepted"
  end

  test "joins user topic" do
    {:ok, join_reply, _socket} =
      RealtimeGateway.UserSocket
      |> socket("user_socket:user_123", %{current_user_id: "user_123", device_id: "dev_123"})
      |> subscribe_and_join(RealtimeGateway.UserChannel, "user:user_123", %{})

    assert join_reply.status == "joined"
    assert join_reply.user_id == "user_123"
    assert join_reply.current_user_id == "user_123"
  end

  test "joins call topic and handles call_signal event" do
    {:ok, join_reply, socket} =
      RealtimeGateway.UserSocket
      |> socket("user_socket:user_123", %{current_user_id: "user_123", device_id: "dev_123"})
      |> subscribe_and_join(RealtimeGateway.CallChannel, "call:call_123", %{})

    assert join_reply.status == "joined"
    assert join_reply.call_id == "call_123"

    ref = push(socket, "call_signal", %{"type" => "offer", "sdp" => "placeholder"})

    assert_reply ref, :ok, reply
    assert reply.event == "call_signal"
    assert reply.call_id == "call_123"
    assert reply.status == "accepted"
  end

  defp start_in_memory_store! do
    case MessageStore.InMemoryAdapter.start_link() do
      {:ok, pid} ->
        Process.unlink(pid)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end

  defp start_auth_repo! do
    case AuthService.Repo.start_link() do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end
end
