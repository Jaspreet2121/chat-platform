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
         # 108: flips to true in the secret-skip test below.
         secret: Application.get_env(:realtime_gateway, :test_conversation_secret, false),
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

  # THE WIRE SHAPE IS THE PRODUCER'S, NOT OURS (2026-09-06). The old fixture hand-typed
  # %{"type" => "message.created"} with top-level ids — an imagined envelope the consumer also
  # matched, so consumer and tests agreed with each other and both disagreed with production, where
  # every event silently no-opped for weeks. This helper builds the envelope through
  # SharedInfra.Events.Envelope.build — the exact constructor EventOutbox publishes through — so the
  # fixture can only drift from the wire if the producer itself changes.
  defp event do
    {:ok, envelope} =
      SharedInfra.Events.Envelope.build(%{
        event_id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
        event_type: "message.created.v1",
        producer: "message-service",
        occurred_at: "2026-09-06T10:00:00Z",
        correlation_id: "corr-auto-reply-test",
        payload: %{
          "conversation_id" => @conversation,
          "message_id" => "msg-1",
          "sender_user_id" => @sender
        }
      })

    Jason.encode!(envelope)
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

  test "LOOP GUARD shapes: the flag is true and \"true\" ONLY — never any other present value" do
    # The stored shape is the string (Messages.stringify_value/1 coerces every metadata value); the
    # sent shape is the boolean. Both must count. Everything else must not — a guard that matched
    # any present value would treat auto:false as automated and silently stop replying.
    for value <- [true, "true"] do
      assert AutoReplyConsumer.auto_message?(%{metadata: %{"auto" => value}}),
             "#{inspect(value)} must count as the auto flag"
    end

    for value <- [false, "false", "TRUE", "True", "yes", 1, "1", nil, ""] do
      refute AutoReplyConsumer.auto_message?(%{metadata: %{"auto" => value}}),
             "#{inspect(value)} must NOT count as the auto flag"
    end

    # Either key spelling, and a message with no metadata at all.
    assert AutoReplyConsumer.auto_message?(%{metadata: %{auto: "true"}})
    refute AutoReplyConsumer.auto_message?(%{metadata: %{}})
    refute AutoReplyConsumer.auto_message?(%{})
  end

  test "ATOM-KEYED settings still fire — no transport can starve the decision core (2026-09-06)" do
    # EXACTLY what the HTTP adapter used to hand the consumer: InternalApi.decode_result rehydrates
    # keys with String.to_existing_atom/1, so only the keys whose atoms already exist convert — a
    # MIXED map. The engine reads Map.get(block, "enabled"), got nil, and skipped every message with
    # reason=disabled for two weeks while the GET endpoint looked perfect.
    Application.put_env(:realtime_gateway, :test_settings, %{
      away: %{},
      greeting: %{
        :enabled => true,
        :body => "Welcome! We reply fast.",
        "audience" => "everyone",
        "resend_after_days" => 14
      }
    })

    assert :ok = AutoReplyConsumer.handle_value(event())

    assert_receive {:claim, claim}
    assert claim["kind"] == "greeting"

    assert_receive {:reply_sent, attrs}
    assert attrs["body"] == "Welcome! We reply fast."
  end

  test "a THROTTLED claim sends nothing (at-least-once redelivery is harmless)" do
    Application.put_env(:realtime_gateway, :test_claim_result, :throttled)

    assert :ok = AutoReplyConsumer.handle_value(event())
    assert_receive {:claim, _}
    refute_receive {:reply_sent, _}, 100
  end

  test "LOOP-PROOF: an inbound message that itself carries the auto flag is skipped outright" do
    # BOTH SHAPES, and the string one is the one production actually stores: the create path
    # coerces every metadata value (Messages.stringify_value/1), so a real auto-reply comes back as
    # "true". This stub hands the consumer a shape of our choosing, which is why the boolean-only
    # version of this test passed for weeks while the guard was dead on every stored message — see
    # MessageService.AutoReplyLoopGuardTest for the round trip that cannot be faked.
    for flag <- [true, "true"] do
      Application.put_env(:realtime_gateway, :test_inbound_metadata, %{
        "auto" => flag,
        "auto_kind" => "away"
      })

      assert :ok = AutoReplyConsumer.handle_value(event())
      refute_receive {:claim, _}, 100
      refute_receive {:reply_sent, _}, 100
    end
  end

  test "SECRET CHATS (108): the engine skips a secret conversation outright — no claim, no reply" do
    Application.put_env(:realtime_gateway, :test_conversation_secret, true)
    on_exit(fn -> Application.delete_env(:realtime_gateway, :test_conversation_secret) end)

    assert :ok = AutoReplyConsumer.handle_value(event())
    refute_receive {:claim, _}, 100
    refute_receive {:reply_sent, _}, 50
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

  test "message.deleted.v1 is matched-and-ignored EXPLICITLY (no warning); junk bytes are ignored" do
    log =
      capture_log(fn ->
        assert :ok =
                 AutoReplyConsumer.handle_value(
                   Jason.encode!(%{"event_type" => "message.deleted.v1", "payload" => %{}})
                 )

        assert :ok = AutoReplyConsumer.handle_value("{not json")
      end)

    refute log =~ "unrecognized envelope"
    refute_receive {:claim, _}, 50
  end

  test "a genuinely unknown envelope WARNS with both key spellings — the silent no-op is dead" do
    log =
      capture_log(fn ->
        # The exact imagined shape the old consumer matched: today it must be loudly unrecognized.
        assert :ok =
                 AutoReplyConsumer.handle_value(
                   Jason.encode!(%{
                     "type" => "message.created",
                     "conversation_id" => @conversation
                   })
                 )
      end)

    assert log =~ "[auto_reply] event ignored: unrecognized envelope"
    assert log =~ "event_type=absent"
    assert log =~ "type=message.created"
    refute_receive {:claim, _}, 50
  end

  test "PRODUCER-ANCHORED: an envelope built inline by Envelope.build evaluates end-to-end" do
    # Deliberately NOT the event/0 helper: if someone reverts the consumer to the imagined shape AND
    # hand-types the helper back to match it (the fixture-mirrors-the-bug failure, again), every
    # helper-based test goes conveniently green — and THIS one stays red, because its shape comes
    # from the producer's own constructor and nothing else.
    {:ok, envelope} =
      SharedInfra.Events.Envelope.build(%{
        event_id: "ffffffff-ffff-4fff-8fff-ffffffffffff",
        event_type: "message.created.v1",
        producer: "message-service",
        occurred_at: "2026-09-06T11:00:00Z",
        correlation_id: "corr-producer-anchored",
        payload: %{
          "conversation_id" => @conversation,
          "message_id" => "msg-2",
          "sender_user_id" => @sender
        }
      })

    assert :ok = AutoReplyConsumer.handle_value(Jason.encode!(envelope))
    assert_receive {:claim, claim}
    assert claim["user_id"] == @recipient
  end

  test "a SEALED skip logs its reason — one INFO line per decision (MUT-4's target)" do
    Application.put_env(:realtime_gateway, :test_conversation_secret, true)
    on_exit(fn -> Application.delete_env(:realtime_gateway, :test_conversation_secret) end)

    log =
      capture_log(fn ->
        assert :ok = AutoReplyConsumer.handle_value(event())
      end)

    assert log =~ "[auto_reply] skip conv=#{@conversation} sender=#{@sender} reason=sealed"
    refute_receive {:claim, _}, 50
  end

  test "a THROTTLED claim logs reason=throttled" do
    Application.put_env(:realtime_gateway, :test_claim_result, :throttled)

    log =
      capture_log(fn ->
        assert :ok = AutoReplyConsumer.handle_value(event())
      end)

    assert log =~ "reason=throttled"
  end
end
