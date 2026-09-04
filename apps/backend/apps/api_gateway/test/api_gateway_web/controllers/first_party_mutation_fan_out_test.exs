defmodule ApiGatewayWeb.FirstPartyMutationFanOutTest do
  @moduledoc """
  THE FIVE MUTATION BROADCASTS the first-party REST paths never emitted.

  react / unreact / update (edit) / delete / delivered returned 200 and broadcast NOTHING — on any
  topic. A peer with the chat OPEN kept rendering deleted content and stale edits until a refetch;
  `/v1` and the socket path had emitted these events all along. (Live-verified on production
  2026-09-04: all three mutation kinds produced zero frames.)

  TWO RULES ENCODED HERE, driven through the REAL controller actions (a helper-level test once went
  green while the controller stayed broken — the M2 lesson):

    1. each path emits the exact event name `/v1` and the socket already use, on the CONVERSATION
       topic;
    2. NONE of them is mirrored to `user:<id>` — these events are not de-duplicated by id, and the
       SDK routes both topics into one channel, so a mirror would render each change twice for
       anyone watching the conversation. Only id-de-duplicated events (message_created) may use the
       two-topic shape. A future change that quietly adds mirroring turns these tests red.

  star/unstar stay silent on purpose: per-user private state, nothing for the peers to render.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.MessageController

  @conversation "11111111-1111-4111-8111-111111111111"
  @sender "22222222-2222-4222-8222-222222222222"
  @peer "33333333-3333-4333-8333-333333333333"
  @message "aaaaaaaa-0000-4000-8000-00000000000a"

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
    def get_conversation(_attrs) do
      {:ok,
       %{
         participants: [
           %{user_id: "22222222-2222-4222-8222-222222222222"},
           %{user_id: "33333333-3333-4333-8333-333333333333"}
         ]
       }}
    end
  end

  defmodule MsgStub do
    @moduledoc false
    @message "aaaaaaaa-0000-4000-8000-00000000000a"

    def update_message(attrs) do
      {:ok,
       %{
         "message_id" => Map.get(attrs, "message_id"),
         "conversation_id" => Map.get(attrs, "conversation_id"),
         "body" => Map.get(attrs, "body"),
         "status" => "active",
         "edited_at" => "2026-09-05T10:00:00.000000Z"
       }}
    end

    def delete_message(attrs) do
      {:ok,
       %{
         "message_id" => Map.get(attrs, "message_id"),
         "conversation_id" => Map.get(attrs, "conversation_id"),
         "status" => "deleted"
       }}
    end

    def add_reaction(_attrs),
      do: {:ok, %{"message_id" => @message, "reactions" => [%{"emoji" => "👍", "count" => 1}]}}

    def remove_reaction(_attrs), do: {:ok, %{"message_id" => @message, "reactions" => []}}

    def mark_delivered(attrs),
      do: {:ok, %{"message_id" => Map.get(attrs, "message_id"), "status" => "delivered"}}

    def star_message(_attrs), do: {:ok, %{"starred" => true}}
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

    # BOTH topics, every test: the refute on user:<peer> is what encodes the no-mirror rule.
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "conversation:#{@conversation}")
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@peer}")

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)

  # Plug.Test conn + direct action call, as the sibling controller tests do it.
  defp call(action, extra \\ %{}) do
    params =
      Map.merge(
        %{"conversation_id" => @conversation, "message_id" => @message},
        extra
      )

    :post
    |> conn("/x", %{})
    |> put_req_header("authorization", "Bearer sender")
    |> then(&apply(MessageController, action, [&1, params]))
  end

  defp assert_conversation_only(event) do
    assert_receive %Phoenix.Socket.Broadcast{topic: "conversation:" <> _, event: ^event} = frame,
                   1000

    refute_receive %Phoenix.Socket.Broadcast{topic: "user:" <> _, event: ^event},
                   300,
                   "#{event} was MIRRORED to a user topic — it is not id-de-duplicated, so every " <>
                     "client watching the conversation just rendered it twice"

    frame
  end

  test "EDIT emits message_updated with the updated message, conversation topic only" do
    conn = call(:update, %{"body" => "edited!"})
    assert conn.status == 200

    frame = assert_conversation_only("message_updated")
    assert frame.payload["message_id"] == @message
    assert frame.payload["body"] == "edited!"
  end

  test "DELETE emits message_deleted, conversation topic only" do
    conn = call(:delete)
    assert conn.status == 200

    frame = assert_conversation_only("message_deleted")
    assert frame.payload["message_id"] == @message
    assert frame.payload["status"] == "deleted"
  end

  test "REACT emits reaction_updated in the socket's exact payload shape" do
    conn = call(:react, %{"emoji" => "👍"})
    assert conn.status == 200

    frame = assert_conversation_only("reaction_updated")

    # KEY-SET assertion: this payload is a serialiser the socket's broadcast_reaction defined first —
    # a missing key cannot fail a partial match, so the whole shape is pinned.
    assert frame.payload |> Map.keys() |> Enum.sort() == [:message_id, :reactions]
    assert frame.payload.message_id == @message
    assert [%{"emoji" => "👍", "count" => 1}] = frame.payload.reactions
  end

  test "UNREACT emits the same reaction_updated frame with the shrunken set" do
    conn = call(:unreact)
    assert conn.status == 200

    frame = assert_conversation_only("reaction_updated")
    assert frame.payload.reactions == []
  end

  test "DELIVERED emits receipt_updated with receipt_type delivered — the socket's frame, ungated" do
    conn = call(:delivered)
    assert conn.status == 200

    frame = assert_conversation_only("receipt_updated")

    assert frame.payload |> Map.keys() |> Enum.sort() ==
             [:conversation_id, :event, :payload, :receipt_type, :status, :user_id]

    assert frame.payload.receipt_type == "delivered"
    assert frame.payload.user_id == @sender
    assert frame.payload.payload == %{"message_id" => @message}
  end

  test "STAR stays silent — per-user private state broadcasts nothing" do
    # star/unstar deliberately have no fan-out; this pins that a future sweep doesn't "fix" them.
    conn = call(:star)
    # whatever the stub-less star path returns, NO frame may appear on either topic
    _ = conn
    refute_receive %Phoenix.Socket.Broadcast{}, 300
  end
end
