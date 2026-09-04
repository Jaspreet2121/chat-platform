defmodule ApiGatewayWeb.ConversationUpdatedUnreadTest do
  @moduledoc """
  The `conversation_updated` frame must carry the unread count INCLUDING the message that triggered it.

  THE DEFECT (device-confirmed). `unread_count` on the wire is `conversation_participants.unread_count`,
  maintained by the SAME Kafka consumer that writes the preview columns. The fan-out fires the moment
  `create_message` returns — before `InboxFromTopic` has run — so the frame shipped the NEW preview beside
  the count from BEFORE the new message. A recipient with the chat CLOSED therefore saw a permanent n-1
  badge (2 messages showed 1, 3 showed 2) which only a REST refetch corrected, because
  `GET /conversations` reads the same column after the consumer landed.

  This is the unfixed half of the freshness defect: `apply_post_write_state/2` was taught to patch
  `updated_at` / `last_message_preview` / `last_message_kind` on the not-yet-landed path and left
  `unread_count` to pass through stale via `updated_row/1`. Its twin — the timestamp/preview half — is
  locked by ConversationUpdatedFreshnessTest; this file locks the counter.

  `ConvStub` stands in for the unprojected row: a stale `updated_at` beside @stale_unread. `LandedConvStub`
  is the same row AFTER the consumer ran, and exists to prove the patch is self-cancelling — the frame
  must not add a second +1 on top of the projection's.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.MessageController

  @conversation "11111111-1111-4111-8111-111111111111"
  @sender "22222222-2222-4222-8222-222222222222"
  @peer "33333333-3333-4333-8333-333333333333"

  # What the unprojected row still holds — the PREVIOUS message's stamp and count.
  @stale_row_at "2026-08-28T06:24:40.305000Z"
  @stale_unread 7
  # What the message we are about to send actually committed as.
  @committed_at "2026-08-28T06:28:01.117204Z"
  # What the projection WILL write once it lands.
  @landed_unread 8

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

    def get_conversation(_attrs) do
      {:ok,
       %{
         app_id: "44444444-4444-4444-8444-444444444444",
         participants: [
           %{user_id: "22222222-2222-4222-8222-222222222222"},
           %{user_id: "33333333-3333-4333-8333-333333333333"}
         ]
       }}
    end

    def authorize_send(_attrs), do: {:ok, %{authorized: true}}

    # ALWAYS unprojected: stale stamp, stale count. The fix must not depend on this ever advancing.
    def inbox_rows(%{"user_ids" => user_ids}) do
      rows =
        Enum.map(user_ids, fn user_id ->
          %{
            user_id: user_id,
            conversation_id: "11111111-1111-4111-8111-111111111111",
            type: "direct",
            title: nil,
            last_message_preview: "the PREVIOUS message",
            last_message_kind: "text",
            unread_count: 7,
            updated_at: "2026-08-28T06:24:40.305000Z"
          }
        end)

      {:ok, %{rows: rows}}
    end
  end

  defmodule LandedConvStub do
    @moduledoc false
    # The consumer already ran: the row carries THIS message's stamp and the +1 it wrote. The frame must
    # pass it through untouched — a second +1 here is the double-count this design forbids.
    def get_conversation_app(_attrs), do: ConvStub.get_conversation_app(nil)
    def get_conversation(attrs), do: ConvStub.get_conversation(attrs)
    def authorize_send(attrs), do: ConvStub.authorize_send(attrs)

    def inbox_rows(%{"user_ids" => user_ids}) do
      rows =
        Enum.map(user_ids, fn user_id ->
          %{
            user_id: user_id,
            conversation_id: "11111111-1111-4111-8111-111111111111",
            type: "direct",
            title: nil,
            last_message_preview: "hello",
            last_message_kind: "text",
            unread_count: 8,
            updated_at: "2026-08-28T06:28:01.117204Z"
          }
        end)

      {:ok, %{rows: rows}}
    end
  end

  defmodule MsgStub do
    @moduledoc false
    # String keys on purpose: the shape the client returns over internal HTTP. The sender gate has to read
    # sender_user_id out of BOTH key styles, exactly as the created_at floor does.
    def create_message(attrs) do
      {:ok,
       %{
         "message_id" => "m-1",
         "conversation_id" => Map.get(attrs, "conversation_id"),
         "sender_user_id" => Map.get(attrs, "sender_user_id"),
         "message_type" => Map.get(attrs, "message_type"),
         "body" => Map.get(attrs, "body"),
         "metadata" => Map.get(attrs, "metadata") || %{},
         "status" => "active",
         "created_at" => "2026-08-28T06:28:01.117204Z"
       }}
    end
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
    Application.put_env(:shared_infra, :message_client_adapter, MsgStub)

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

  defp send_first_party(body) do
    :post
    |> conn("/api/v1/conversations/#{@conversation}/messages", %{})
    |> put_req_header("authorization", "Bearer sender")
    |> MessageController.create(Map.put(body, "conversation_id", @conversation))
  end

  # The frame for ONE user topic. Subscribing per-user is what makes the sender/recipient distinction
  # assertable at all — both rows come off the same fan-out.
  defp await_frame(user_id) do
    receive do
      %Phoenix.Socket.Broadcast{
        topic: "user:" <> ^user_id,
        event: "conversation_updated",
        payload: payload
      } ->
        payload
    after
      1500 -> flunk("no conversation_updated frame for #{user_id}")
    end
  end

  describe "the not-yet-landed frame (the n-1 badge)" do
    test "a RECIPIENT's frame carries the stale count PLUS the message that triggered it" do
      Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@peer}")

      send_first_party(%{"message_type" => "text", "body" => "hello"})

      payload = await_frame(@peer)

      # The whole defect in one assertion: @stale_unread on the wire is the n-1 badge.
      assert payload["unread_count"] == @stale_unread + 1,
             "recipient frame carried #{inspect(payload["unread_count"])} — the row's unprojected " <>
               "count. The badge shows n-1 until a REST refetch."
    end

    test "the SENDER's own frame does NOT gain unread" do
      Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@sender}")

      send_first_party(%{"message_type" => "text", "body" => "hello"})

      payload = await_frame(@sender)

      # Mirrors the projection's own `cp.user_id <> $2`: your own message never raises your own unread.
      assert payload["unread_count"] == @stale_unread,
             "sender frame gained unread from their OWN message"
    end

    test "the frame still carries the fresh preview and stamp (the trio must not regress)" do
      Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@peer}")

      send_first_party(%{"message_type" => "text", "body" => "hello"})

      payload = await_frame(@peer)

      assert payload["updated_at"] == @committed_at
      assert payload["last_message_preview"] == "hello"
      refute payload["updated_at"] == @stale_row_at
    end
  end

  describe "the landed frame (the double-count guard)" do
    setup do
      Application.put_env(:shared_infra, :conversation_client_adapter, LandedConvStub)
      :ok
    end

    test "a row the projection ALREADY incremented is passed through, not incremented again" do
      Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@peer}")

      send_first_party(%{"message_type" => "text", "body" => "hello"})

      payload = await_frame(@peer)

      # newer?/2 compares EQUAL here (the row's updated_at IS this message's stamp), so the whole
      # override branch is skipped and the projection's own +1 stands alone. A frame of 9 would mean the
      # patch double-counts the moment the consumer wins the race.
      assert payload["unread_count"] == @landed_unread,
             "frame double-counted: the projection's +1 and the broadcast's +1 both applied"
    end
  end
end
