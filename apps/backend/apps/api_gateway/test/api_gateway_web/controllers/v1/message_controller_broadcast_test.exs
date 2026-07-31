defmodule ApiGatewayWeb.V1.MessageControllerBroadcastTest do
  @moduledoc """
  The /v1 REST send must fan out to connected sockets exactly like the socket path — once, and never on
  an idempotent replay. Stubs the conversation + message clients, subscribes to the endpoint's PubSub,
  and calls the controller action directly (bypassing V1Auth by setting the assigns).
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.V1.MessageController

  @conversation_id "11111111-1111-4111-8111-111111111111"
  @sender "22222222-2222-4222-8222-222222222222"
  @other "33333333-3333-4333-8333-333333333333"
  @app_id "44444444-4444-4444-8444-444444444444"

  defmodule ConvStub do
    @moduledoc false
    @behaviour SharedInfra.ConversationClient
    @impl true
    def get_conversation_app(_attrs), do: {:ok, %{}}
    @impl true
    def get_conversation(_attrs) do
      # Carries app_id (the end-user gate pins it) AND participants (fan_out reads them). @sender is an
      # active participant, so authorize_conversation passes.
      {:ok,
       %{
         app_id: "44444444-4444-4444-8444-444444444444",
         participants: [
           %{user_id: "22222222-2222-4222-8222-222222222222"},
           %{user_id: "33333333-3333-4333-8333-333333333333"}
         ]
       }}
    end

    # Per-user inbox rows for the conversation_updated fan-out. The SENDER's row has unread 0 (your own
    # message never counts against you); the other participant's is 1. Mirrors what the real SQL returns.
    @impl true
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
            unread_count: if(user_id == "22222222-2222-4222-8222-222222222222", do: 0, else: 1),
            updated_at: "2026-07-14T10:00:00.000000Z"
          }
        end)

      {:ok, %{rows: rows}}
    end
  end

  # get_conversation works (so the send is authorized) but the inbox-row fetch raises — proving a broken
  # fan-out cannot take the primary action down with it.
  defmodule ExplodingConvStub do
    @moduledoc false
    @behaviour SharedInfra.ConversationClient
    @impl true
    def get_conversation_app(_attrs), do: {:ok, %{}}
    @impl true
    def get_conversation(_attrs),
      do:
        {:ok,
         %{
           app_id: "44444444-4444-4444-8444-444444444444",
           participants: [%{user_id: "22222222-2222-4222-8222-222222222222"}]
         }}

    @impl true
    def inbox_rows(_attrs), do: raise("inbox_rows is down")
  end

  defmodule MsgStub do
    @moduledoc false
    @behaviour SharedInfra.MessageClient
    @message %{
      "message_id" => "msg-1",
      "conversation_id" => "11111111-1111-4111-8111-111111111111",
      "sender_user_id" => "22222222-2222-4222-8222-222222222222",
      "message_type" => "text",
      "body" => "hello",
      "status" => "active"
    }
    def message, do: @message
    @impl true
    def create_message(_attrs), do: {:ok, @message}
  end

  setup do
    prev_conv = Application.get_env(:shared_infra, :conversation_client_adapter)
    prev_msg = Application.get_env(:shared_infra, :message_client_adapter)
    prev_backend = System.get_env("V1_RUNTIME_BACKEND")
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :message_client_adapter, MsgStub)

    # Force the in-process ETS idem cache (redis isn't running in test) so the replay branch is exercised.
    System.put_env("V1_RUNTIME_BACKEND", "ets")

    on_exit(fn ->
      restore(:conversation_client_adapter, prev_conv)
      restore(:message_client_adapter, prev_msg)

      if prev_backend,
        do: System.put_env("V1_RUNTIME_BACKEND", prev_backend),
        else: System.delete_env("V1_RUNTIME_BACKEND")
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)

  # A conn with the V1Auth assigns already set (as the plug would leave them).
  defp v1_conn(idempotency_key \\ nil) do
    conn =
      :post
      |> conn("/v1/conversations/#{@conversation_id}/messages", %{})
      |> assign(:v1_app_id, @app_id)
      |> assign(:v1_actor, :end_user)
      |> assign(:v1_user_id, @sender)

    if idempotency_key, do: put_req_header(conn, "idempotency-key", idempotency_key), else: conn
  end

  defp send_body, do: %{"id" => @conversation_id, "message_type" => "text", "body" => "hello"}

  test "a plain send broadcasts message_created on the conversation topic" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "conversation:#{@conversation_id}")

    conn = MessageController.create(v1_conn(), send_body())
    assert conn.status == 201

    assert_receive %Phoenix.Socket.Broadcast{
                     event: "message_created",
                     payload: payload
                   },
                   1000

    assert payload == MsgStub.message()
  end

  test "a send mirrors message_created to a NON-sender participant's user topic but NOT the sender's" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@other}")

    MessageController.create(v1_conn(), send_body())

    # The other participant gets the mirror…
    assert_receive %Phoenix.Socket.Broadcast{event: "message_created"}, 1000
  end

  # DELIBERATE CHANGE (conversation.updated): the sender's user topic used to receive NOTHING at all, and this
  # test asserted exactly that. It still receives no message_created — but it DOES now receive
  # conversation_updated, because the sender's own INBOX ROW changed too (new preview, new updated_at, the
  # conversation jumps to the top of their list). What must never happen is the sender's UNREAD going up.
  test "message_created is still NOT mirrored to the sender — but conversation_updated IS, with unread 0" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@sender}")

    MessageController.create(v1_conn(), send_body())

    assert_receive %Phoenix.Socket.Broadcast{event: "conversation_updated", payload: payload},
                   1000

    assert payload["unread_count"] == 0
    assert payload["last_message_preview"] == "hello"
    # The routing key is not part of the wire frame.
    refute Map.has_key?(payload, "user_id")

    refute_receive %Phoenix.Socket.Broadcast{event: "message_created"}, 300
  end

  test "a send fans conversation_updated to EVERY participant, each with THEIR OWN unread" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@other}")

    MessageController.create(v1_conn(), send_body())

    # The non-sender's row carries unread 1 (the message they haven't read); the sender's carries 0 (asserted
    # above). Same conversation, different rows — the whole point of the per-user fan-out.
    assert_receive %Phoenix.Socket.Broadcast{event: "conversation_updated", payload: payload},
                   1000

    assert payload["unread_count"] == 1
    assert payload["conversation_id"] == @conversation_id
  end

  test "a broadcast failure NEVER fails the send (fire-and-forget)" do
    # inbox_rows blows up → the conversation_updated fan-out dies in its Task and is logged, but the 201 for
    # the primary action still goes out.
    Application.put_env(:shared_infra, :conversation_client_adapter, ExplodingConvStub)

    conn = MessageController.create(v1_conn(), send_body())
    assert conn.status == 201
  end

  test "a repeated POST with the SAME Idempotency-Key broadcasts exactly ONCE" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "conversation:#{@conversation_id}")

    # Unique per run — the ETS idem cache lives for the whole suite, so a fixed key could be pre-cached.
    key = "idem-#{System.unique_integer([:positive])}"

    conn1 = MessageController.create(v1_conn(key), send_body())
    assert conn1.status == 201
    assert_receive %Phoenix.Socket.Broadcast{event: "message_created"}, 1000

    # Replay: same key → same message returned, but NO second broadcast.
    conn2 = MessageController.create(v1_conn(key), send_body())
    assert conn2.status == 201
    refute_receive %Phoenix.Socket.Broadcast{}, 500
  end
end
