defmodule ApiGatewayWeb.RestReadReceiptTest do
  @moduledoc """
  A read marked over REST emits the SAME `receipt_updated` frame the socket's `message_read` emits —
  same emitter (`RealtimeGateway.Receipts`), same reciprocity gate, AFTER the receipt row is
  committed. Before this, REST readers moved nobody's ticks until the next reload.

  The commit-ordering proof: the controller runs IN THIS TEST PROCESS (Plug.Test), so a frame
  broadcast before `mark_read` would already sit in this mailbox when the store stub runs — the
  stub looks, and records what it saw.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.MessageController

  @conversation "11111111-1111-4111-8111-111111111111"
  @reader "22222222-2222-4222-8222-222222222222"
  @peer "33333333-3333-4333-8333-333333333333"
  @message "aaaaaaaa-0000-4000-8000-0000000000aa"

  defmodule AuthStub do
    @moduledoc false
    def current_session(%{"authorization" => "Bearer reader"}),
      do: {:ok, %{user_id: "22222222-2222-4222-8222-222222222222", app_id: "app1"}}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule ConvStub do
    @moduledoc false
    def get_conversation(_attrs) do
      {:ok,
       %{
         conversation_id: "11111111-1111-4111-8111-111111111111",
         type: "direct",
         participants: [
           %{user_id: "22222222-2222-4222-8222-222222222222"},
           %{user_id: "33333333-3333-4333-8333-333333333333"}
         ]
       }}
    end

    def inbox_rows(%{"user_ids" => ids}),
      do:
        {:ok,
         %{
           rows:
             Enum.map(
               ids,
               &%{
                 user_id: &1,
                 conversation_id: "11111111-1111-4111-8111-111111111111",
                 unread_count: 1,
                 updated_at: "2026-09-15T00:00:00Z"
               }
             )
         }}
  end

  defmodule UserStub do
    @moduledoc false
    def get_privacy(%{"user_id" => user_id}) do
      disabled = Application.get_env(:api_gateway, :rest_read_receipt_disabled_for, [])
      {:ok, %{read_receipts_enabled: user_id not in disabled}}
    end
  end

  # Records the commit AND whether a receipt frame had ALREADY been broadcast when the commit ran.
  defmodule MsgStub do
    @moduledoc false
    def mark_read(attrs) do
      early? =
        receive do
          %Phoenix.Socket.Broadcast{event: "receipt_updated"} = frame ->
            # Put it back so the test's own assertion still sees it.
            send(self(), frame)
            true
        after
          0 -> false
        end

      Process.put(:frame_before_commit, early?)
      Process.put(:committed, {:read, attrs["message_id"], attrs["user_id"]})
      {:ok, %{message_id: attrs["message_id"], status: "read"}}
    end

    def mark_delivered(attrs) do
      Process.put(:committed, {:delivered, attrs["message_id"], attrs["user_id"]})
      {:ok, %{message_id: attrs["message_id"], status: "delivered"}}
    end
  end

  setup do
    keys = [
      {:shared_infra, :auth_client_adapter},
      {:shared_infra, :conversation_client_adapter},
      {:shared_infra, :user_client_adapter},
      {:shared_infra, :message_client_adapter},
      {:api_gateway, :rest_read_receipt_disabled_for},
      {:message_service, :message_persistence}
    ]

    prev = for {app, key} <- keys, into: %{}, do: {{app, key}, Application.get_env(app, key)}

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :user_client_adapter, UserStub)
    Application.put_env(:shared_infra, :message_client_adapter, MsgStub)
    Application.put_env(:api_gateway, :rest_read_receipt_disabled_for, [])
    Application.put_env(:message_service, :message_persistence, true)

    on_exit(fn ->
      for {{app, key}, value} <- prev do
        if value == nil,
          do: Application.delete_env(app, key),
          else: Application.put_env(app, key, value)
      end
    end)

    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "conversation:#{@conversation}")
    Process.delete(:frame_before_commit)
    Process.delete(:committed)
    :ok
  end

  defp read do
    :post
    |> conn("/api/v1/conversations/#{@conversation}/messages/#{@message}/read", %{})
    |> put_req_header("authorization", "Bearer reader")
    |> MessageController.read(%{"conversation_id" => @conversation, "message_id" => @message})
  end

  defp delivered do
    :post
    |> conn("/api/v1/conversations/#{@conversation}/messages/#{@message}/delivered", %{})
    |> put_req_header("authorization", "Bearer reader")
    |> MessageController.delivered(%{
      "conversation_id" => @conversation,
      "message_id" => @message
    })
  end

  test "REST read emits the socket's receipt_updated frame on the conversation topic, key-set pinned (MUT-1 guard)" do
    assert read().status == 200

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "conversation:" <> @conversation,
      event: "receipt_updated",
      payload: payload
    }

    assert payload == %{
             event: "message_read",
             conversation_id: @conversation,
             user_id: @reader,
             payload: %{"message_id" => @message},
             status: "accepted",
             receipt_type: "read"
           }

    assert Map.keys(payload) |> Enum.sort() ==
             [:conversation_id, :event, :payload, :receipt_type, :status, :user_id]
  end

  test "MUT-2 guard: the frame is emitted AFTER the receipt row is committed" do
    read()
    assert Process.get(:committed) == {:read, @message, @reader}
    assert Process.get(:frame_before_commit) == false
    assert_receive %Phoenix.Socket.Broadcast{event: "receipt_updated"}
  end

  test "the socket's reciprocity gate applies: a DM peer with read receipts OFF gets no read tick; the read is still stored" do
    Application.put_env(:api_gateway, :rest_read_receipt_disabled_for, [@peer])
    assert read().status == 200
    assert Process.get(:committed) == {:read, @message, @reader}
    refute_receive %Phoenix.Socket.Broadcast{event: "receipt_updated"}, 100
  end

  test "the reader's OWN setting OFF suppresses the tick too" do
    Application.put_env(:api_gateway, :rest_read_receipt_disabled_for, [@reader])
    assert read().status == 200
    refute_receive %Phoenix.Socket.Broadcast{event: "receipt_updated"}, 100
  end

  test "REST delivered emits the delivered frame through the same emitter, never gated" do
    Application.put_env(:api_gateway, :rest_read_receipt_disabled_for, [@reader, @peer])
    assert delivered().status == 200

    assert_receive %Phoenix.Socket.Broadcast{
      event: "receipt_updated",
      payload: %{
        event: "message_delivered",
        receipt_type: "delivered",
        payload: %{"message_id" => @message}
      }
    }
  end
end
