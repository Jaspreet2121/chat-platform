defmodule ApiGatewayWeb.FirstPartyFanOutTest do
  @moduledoc """
  THE TWO-TOPIC RULE for the FIRST-PARTY paths.

  Clients join `conversation:<id>` only for the chat they have OPEN (ConversationChannel refuses to
  join them all — it would falsely mark a user present everywhere). So a conversation-topic broadcast
  reaches only the people looking at that chat, and anything needed otherwise must ALSO hit
  `user:<id>`.

  Two live bugs came from missing that:
    * the first-party message create broadcast NO message_created at all — a recipient got an unread
      bump and had to pull-to-refresh, and one with the chat open saw nothing;
    * view_once_opened was conversation-only, so it never reached the SENDER — the one participant
      guaranteed not to have the chat open, and the only one who needs it.

  These subscribe to the real PubSub the endpoint broadcasts on and assert BOTH topics receive it.
  """
  use ExUnit.Case, async: false

  alias ApiGatewayWeb.RealtimeFanOut

  @conversation "11111111-1111-4111-8111-111111111111"
  @actor "22222222-2222-4222-8222-222222222222"
  @other "33333333-3333-4333-8333-333333333333"
  @third "44444444-4444-4444-8444-444444444444"

  defmodule ConvStub do
    @moduledoc false
    @actor "22222222-2222-4222-8222-222222222222"
    @other "33333333-3333-4333-8333-333333333333"
    @third "44444444-4444-4444-8444-444444444444"

    def get_conversation(_attrs) do
      {:ok,
       %{
         participants: [
           %{user_id: @actor},
           %{user_id: @other},
           %{user_id: @third}
         ]
       }}
    end
  end

  defmodule EmptyConvStub do
    @moduledoc false
    def get_conversation(_attrs), do: {:error, :conversation_forbidden}
  end

  setup do
    previous = Application.get_env(:shared_infra, :conversation_client_adapter)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:shared_infra, :conversation_client_adapter, previous),
        else: Application.delete_env(:shared_infra, :conversation_client_adapter)
    end)

    :ok
  end

  describe "to_participants/4 — the shared rule" do
    test "reaches the conversation topic AND every other participant's user topic" do
      Phoenix.PubSub.subscribe(ApiGateway.PubSub, "conversation:#{@conversation}")
      Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@other}")
      Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@third}")

      RealtimeFanOut.to_participants(@conversation, @actor, "message_created", %{id: "m1"})

      # The open chat.
      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "conversation:" <> _,
                       event: "message_created",
                       payload: %{id: "m1"}
                     },
                     1000

      # ...and everyone who does NOT have it open. This is the half that was missing.
      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "user:" <> _,
                       event: "message_created"
                     },
                     1000

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "user:" <> _,
                       event: "message_created"
                     },
                     1000
    end

    test "the ACTOR is excluded — no echo of your own action to yourself" do
      Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@actor}")

      RealtimeFanOut.to_participants(@conversation, @actor, "message_created", %{id: "m2"})

      refute_receive %Phoenix.Socket.Broadcast{topic: "user:" <> _}, 300
    end

    test "PAYLOAD IS IDENTICAL on both topics — one client decoder, not two" do
      Phoenix.PubSub.subscribe(ApiGateway.PubSub, "conversation:#{@conversation}")
      Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@other}")

      payload = %{message_id: "m3", body: "hello", view_once: false}
      RealtimeFanOut.to_participants(@conversation, @actor, "message_created", payload)

      assert_receive %Phoenix.Socket.Broadcast{topic: "conversation:" <> _, payload: ^payload},
                     1000

      assert_receive %Phoenix.Socket.Broadcast{topic: "user:" <> _, payload: ^payload}, 1000
    end

    test "an unresolvable conversation still reaches the conversation topic, and fans out to nobody" do
      # The participant read is best-effort: a fan-out must never fail the request that caused it.
      Application.put_env(:shared_infra, :conversation_client_adapter, EmptyConvStub)
      Phoenix.PubSub.subscribe(ApiGateway.PubSub, "conversation:#{@conversation}")
      Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@other}")

      RealtimeFanOut.to_participants(@conversation, @actor, "message_created", %{id: "m4"})

      assert_receive %Phoenix.Socket.Broadcast{topic: "conversation:" <> _}, 1000
      refute_receive %Phoenix.Socket.Broadcast{topic: "user:" <> _}, 300
    end

    test "participants_except/2 drops the actor and any nil" do
      assert RealtimeFanOut.participants_except(@conversation, @actor) |> Enum.sort() ==
               Enum.sort([@other, @third])

      refute @actor in RealtimeFanOut.participants_except(@conversation, @actor)
    end
  end

  describe "view_once_opened reaches the SENDER" do
    test "the opener is excluded and every OTHER participant's user topic gets it" do
      # The whole point: the message's SENDER is who needs "Opened", and they are the one participant
      # guaranteed NOT to have the chat open. Conversation-only could never have reached them, so
      # this event has never worked in production since it shipped.
      Phoenix.PubSub.subscribe(ApiGateway.PubSub, "conversation:#{@conversation}")
      Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@other}")
      Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@actor}")

      frame = %{message_id: "m9", user_id: @actor, opened_at: "2026-09-04T00:00:00Z"}
      RealtimeFanOut.to_participants(@conversation, @actor, "view_once_opened", frame)

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "conversation:" <> _,
                       event: "view_once_opened",
                       payload: ^frame
                     },
                     1000

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "user:" <> _,
                       event: "view_once_opened",
                       payload: ^frame
                     },
                     1000

      # ...but never back to the opener, who already has the 200.
      refute_receive %Phoenix.Socket.Broadcast{
                       topic: "user:22222222-2222-4222-8222-222222222222"
                     },
                     300
    end
  end

  # THROUGH THE CONTROLLER, not the helper. The helper test above passes even if the controller never
  # calls it — proven: reverting view_once_controller to a conversation-only broadcast left it green.
  # A mutation that survives is a test that is not testing the thing.
  describe "ViewOnceController.open/2 actually fans out" do
    defmodule AuthStub do
      @moduledoc false
      def current_session(%{"authorization" => "Bearer " <> user_id}) when user_id != "",
        do: {:ok, %{user_id: user_id, app_id: "44444444-4444-4444-8444-444444444444"}}

      def current_session(_), do: {:error, :session_invalid}
    end

    defmodule MsgStub do
      @moduledoc false
      def open_view_once(_attrs),
        do: {:ok, %{opened_at: "2026-09-04T00:00:00Z", media_id: "med-1", first_open: false}}

      def expired_view_once_media(_attrs), do: {:ok, %{media_ids: []}}
    end

    setup do
      prev_auth = Application.get_env(:shared_infra, :auth_client_adapter)
      prev_msg = Application.get_env(:shared_infra, :message_client_adapter)
      Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
      Application.put_env(:shared_infra, :message_client_adapter, MsgStub)

      on_exit(fn ->
        if prev_auth,
          do: Application.put_env(:shared_infra, :auth_client_adapter, prev_auth),
          else: Application.delete_env(:shared_infra, :auth_client_adapter)

        if prev_msg,
          do: Application.put_env(:shared_infra, :message_client_adapter, prev_msg),
          else: Application.delete_env(:shared_infra, :message_client_adapter)
      end)

      :ok
    end

    test "the SENDER's user topic receives view_once_opened, not just the conversation" do
      Phoenix.PubSub.subscribe(ApiGateway.PubSub, "conversation:#{@conversation}")
      Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@other}")

      conn =
        :post
        |> Plug.Test.conn("/api/v1/conversations/#{@conversation}/messages/m1/open", %{})
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> @actor)
        |> ApiGatewayWeb.ViewOnceController.open(%{
          "conversation_id" => @conversation,
          "message_id" => "m1"
        })

      assert conn.status == 200

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "conversation:" <> _,
                       event: "view_once_opened"
                     },
                     1500

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "user:" <> _,
                       event: "view_once_opened"
                     },
                     1500
    end
  end

  describe "the DEDUP contract that makes the mirror safe" do
    test "a client in BOTH topics receives the same event twice, deduplicated by id downstream" do
      # Stated as a test because it is the reason only message_created (and view_once_opened, which
      # is idempotent per (message, user)) may be mirrored. Edits/deletes/receipts are NOT
      # de-duplicated by id downstream, which is why V1.MessageController.fan_out_mutation/3 keeps
      # them conversation-only — mirroring those would render each twice.
      Phoenix.PubSub.subscribe(ApiGateway.PubSub, "conversation:#{@conversation}")
      Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@other}")

      RealtimeFanOut.to_participants(@conversation, @actor, "message_created", %{
        message_id: "dup"
      })

      assert_receive %Phoenix.Socket.Broadcast{payload: %{message_id: "dup"}}, 1000
      assert_receive %Phoenix.Socket.Broadcast{payload: %{message_id: "dup"}}, 1000

      # Both copies carry the SAME message_id, which is what lets an idempotent merge collapse them.
      refute_receive %Phoenix.Socket.Broadcast{}, 300
    end
  end
end
