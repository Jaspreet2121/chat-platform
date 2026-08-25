defmodule RealtimeGateway.AutoReplyConsumerTest do
  @moduledoc """
  The engine's transport half (102), no Kafka/DB: the full evaluate → claim → send path with every
  client stubbed; the reply is a REAL text message with the {auto, auto_kind} metadata convention
  and the pill-style triple broadcast; a throttled claim sends NOTHING; an inbound auto message is
  loop-proof; and ASYNC ISOLATION — a raising evaluator still commits (mutation-proven).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias RealtimeGateway.AutoReplyConsumer

  @sender "11111111-1111-1111-1111-111111111111"
  @recipient "22222222-2222-2222-2222-222222222222"
  @conversation "33333333-3333-3333-3333-333333333333"
  @app "44444444-4444-4444-8444-444444444444"

  defmodule MessageStub do
    @moduledoc false
    def get_message(attrs) do
      metadata = Application.get_env(:realtime_gateway, :test_inbound_metadata, %{})

      {:ok,
       %{
         message_id: attrs["message_id"],
         conversation_id: attrs["conversation_id"],
         metadata: metadata,
         created_at: "2026-08-26T10:00:00Z"
       }}
    end

    def create_message(attrs) do
      send(:auto_reply_test, {:reply_sent, attrs})
      {:ok, Map.put(attrs, "message_id", "auto-reply-1")}
    end
  end

  defmodule ConversationStub do
    @moduledoc false
    def get_conversation(_attrs) do
      {:ok,
       %{
         conversation_id: "33333333-3333-3333-3333-333333333333",
         type: "direct",
         # Old last activity → greeting's idle condition holds.
         updated_at: "2026-07-01T00:00:00Z",
         participants: [
           %{user_id: "11111111-1111-1111-1111-111111111111", role: "member"},
           %{user_id: "22222222-2222-2222-2222-222222222222", role: "member"}
         ]
       }}
    end

    def get_conversation_app(_attrs),
      do: {:ok, %{app_id: "44444444-4444-4444-8444-444444444444", type: "direct"}}

    def either_blocked?(_attrs), do: {:ok, %{blocked: false}}
  end

  defmodule UserStub do
    @moduledoc false
    def get_auto_replies(_attrs) do
      {:ok, Application.get_env(:realtime_gateway, :test_settings, %{away: %{}, greeting: %{}})}
    end

    def claim_auto_reply(attrs) do
      send(:auto_reply_test, {:claim, attrs})
      {:ok, Application.get_env(:realtime_gateway, :test_claim_result, :claimed)}
    end

    def list_favourites(_attrs), do: {:ok, %{favourites: []}}
  end

  defmodule CaptureEndpoint do
    @moduledoc false
    def broadcast(topic, event, payload) do
      send(:auto_reply_test, {:broadcast, topic, event, payload})
      :ok
    end
  end

  setup do
    Process.register(self(), :auto_reply_test)

    keys = [
      {:shared_infra, :message_client_adapter, MessageStub},
      {:shared_infra, :conversation_client_adapter, ConversationStub},
      {:shared_infra, :user_client_adapter, UserStub},
      {:realtime_gateway, :endpoint, CaptureEndpoint}
    ]

    prev = for {app, key, _} <- keys, do: {app, key, Application.get_env(app, key)}
    for {app, key, value} <- keys, do: Application.put_env(app, key, value)

    Application.put_env(:realtime_gateway, :test_settings, %{
      away: %{},
      greeting: %{
        "enabled" => true,
        "audience" => "everyone",
        "body" => "Welcome! We reply fast.",
        "resend_after_days" => 14
      }
    })

    on_exit(fn ->
      for {app, key, value} <- prev do
        if value, do: Application.put_env(app, key, value), else: Application.delete_env(app, key)
      end

      for key <- [:test_settings, :test_claim_result, :test_inbound_metadata] do
        Application.delete_env(:realtime_gateway, key)
      end
    end)

    :ok
  end

  defp event do
    Jason.encode!(%{
      "type" => "message.created",
      "conversation_id" => @conversation,
      "message_id" => "msg-1",
      "sender_user_id" => @sender
    })
  end

  test "the full path: claim rides the settings window, the reply is a REAL flagged text, triple broadcast" do
    assert :ok = AutoReplyConsumer.handle_value(event())

    assert_receive {:claim, claim}
    assert claim["user_id"] == @recipient
    assert claim["app_id"] == @app
    assert claim["kind"] == "greeting"
    assert claim["window_seconds"] == 14 * 86_400

    assert_receive {:reply_sent, attrs}
    assert attrs["conversation_id"] == @conversation
    # FROM the recipient, as a normal text, carrying the same metadata convention other kinds use.
    assert attrs["sender_user_id"] == @recipient
    assert attrs["message_type"] == "text"
    assert attrs["body"] == "Welcome! We reply fast."
    assert attrs["metadata"] == %{"auto" => true, "auto_kind" => "greeting"}

    # The pill-pattern fan-out: conversation topic + both user topics.
    assert_receive {:broadcast, "conversation:" <> @conversation, "message_created", _}
    assert_receive {:broadcast, "user:" <> @sender, "message_created", _}
    assert_receive {:broadcast, "user:" <> @recipient, "message_created", _}
  end

  test "a THROTTLED claim sends nothing (at-least-once redelivery is harmless)" do
    Application.put_env(:realtime_gateway, :test_claim_result, :throttled)

    assert :ok = AutoReplyConsumer.handle_value(event())
    assert_receive {:claim, _}
    refute_receive {:reply_sent, _}, 100
  end

  test "LOOP-PROOF: an inbound message that itself carries the auto flag is skipped outright" do
    Application.put_env(:realtime_gateway, :test_inbound_metadata, %{
      "auto" => true,
      "auto_kind" => "away"
    })

    assert :ok = AutoReplyConsumer.handle_value(event())
    refute_receive {:claim, _}, 100
    refute_receive {:reply_sent, _}, 100
  end

  test "both features disabled → nothing happens (the default state is invisible)" do
    Application.put_env(:realtime_gateway, :test_settings, %{away: %{}, greeting: %{}})

    assert :ok = AutoReplyConsumer.handle_value(event())
    refute_receive {:claim, _}, 100
  end

  test "ASYNC ISOLATION: a crashing evaluation logs and still returns :ok (the partition never wedges)" do
    # A message client that raises — the exact shape of an engine bug in production.
    defmodule BoomClient do
      def get_message(_attrs), do: raise("boom")
    end

    Application.put_env(:shared_infra, :message_client_adapter, BoomClient)

    log =
      capture_log(fn ->
        assert :ok = AutoReplyConsumer.handle_value(event())
      end)

    assert log =~ "[auto_reply] evaluation crashed"
    refute_receive {:reply_sent, _}, 50
  end

  test "non-created event types and junk bytes are ignored" do
    assert :ok = AutoReplyConsumer.handle_value(Jason.encode!(%{"type" => "message.deleted"}))
    assert :ok = AutoReplyConsumer.handle_value("{not json")
    refute_receive {:claim, _}, 50
  end
end
