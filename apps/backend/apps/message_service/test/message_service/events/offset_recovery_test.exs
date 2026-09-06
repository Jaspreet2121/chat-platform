defmodule MessageService.Events.OffsetRecoveryTest do
  @moduledoc """
  A CONSUMER MUST SURVIVE `offset_out_of_range` — the wedge that idled the inbox projection for
  ~7 hours on 2026-09-04 (committed 165 < earliest 219 on partition 4; zero commits, zero log lines).

  Mechanism under test: brod's default `reset_by_subscriber` policy SUSPENDS the partition and casts
  `{ConsumerPid, #kafka_fetch_error{}}` to the worker, which forwards it to the callback's OPTIONAL
  `handle_info/2`. A callback without that export swallows the cast (brod_utils:optional_callback's
  default) and the partition never resumes — the resubscribe timer skips alive-but-suspended
  consumers. So these tests pin BOTH halves: every consumer EXPORTS the hook, and the hook
  resubscribes THAT consumer at `:earliest`.

  The fake consumer below stands in for brod_consumer: `:brod.subscribe(ConsumerPid, self(), Opts)`
  is `GenServer.call(Pid, {:subscribe, SubscriberPid, Opts})` (brod_consumer.erl:272-273), so a stub
  GenServer receives exactly what a real consumer would.

  SECOND WEDGE (2026-09-05, twice in 24h, broker innocent): a dropped payload connection replaces a
  consumer, the worker's 2s loop skips any partition holding un-acked (:retry) deliveries FOREVER,
  and NOTHING reaches the callback. The liveness backstop probes the client's current consumer pid
  each interval and, on a change, re-subscribes at the COMMITTED offset — never :earliest (the
  out-of-range path's choice) and never :latest. MUT-3 pins that the two paths never collapse.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Record

  alias MessageService.Events.OffsetRecovery

  Record.defrecordp(
    :kafka_fetch_error,
    Record.extract(:kafka_fetch_error, from_lib: "brod/include/brod.hrl")
  )

  defmodule FakeConsumer do
    @moduledoc false
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call({:subscribe, subscriber_pid, opts}, _from, test_pid) do
      send(test_pid, {:subscribed, subscriber_pid, opts})
      {:reply, :ok, test_pid}
    end
  end

  defp state(partition) do
    OffsetRecovery.init_state(
      %{
        group_id: "message-service-inbox-projection",
        topic: "message.events.v1",
        partition: partition
      },
      nil
    )
  end

  defp out_of_range(partition) do
    kafka_fetch_error(
      topic: "message.events.v1",
      partition: partition,
      error_code: :offset_out_of_range,
      error_desc: ~c""
    )
  end

  # The four brod callback modules that consume message.events.v1. ALL share the exposure — a
  # committed offset can fall out of range for any group — so all four must export the hook. This
  # list is the guard against the fix quietly covering three of four surfaces.
  @consumers [
    MessageService.Events.InboxProjectionConsumer,
    MessageService.Events.SearchIndexConsumer,
    MessageService.Events.ConversationSummaryConsumer,
    MessageService.Events.MessageCreatedLogConsumer
  ]

  test "every consumer on the topic exports handle_info/2 — the optional hook brod swallows without" do
    for consumer <- @consumers do
      Code.ensure_loaded!(consumer)

      assert function_exported?(consumer, :handle_info, 2),
             "#{inspect(consumer)} does not export handle_info/2: an offset_out_of_range fetch " <>
               "error would be silently swallowed and the partition suspended forever"
    end
  end

  test "offset_out_of_range RESUBSCRIBES that consumer at :earliest, from the worker's own pid" do
    {:ok, consumer_pid} = FakeConsumer.start_link(self())

    log =
      capture_log(fn ->
        assert {:noreply, _state} =
                 MessageService.Events.InboxProjectionConsumer.handle_info(
                   {consumer_pid, out_of_range(4)},
                   state(4)
                 )
      end)

    # The resume half: the suspended brod_consumer got a re-subscribe from the registered
    # subscriber (self() here — handle_info runs in the worker process), at :earliest and NEVER
    # :latest, so only broker-deleted events are skipped.
    assert_receive {:subscribed, subscriber_pid, opts}
    assert subscriber_pid == self()
    assert Keyword.fetch!(opts, :begin_offset) == :earliest

    # The detection half: loud, named, and quantified as far as the broker allows.
    assert log =~ "OFFSET OUT OF RANGE"
    assert log =~ "group=message-service-inbox-projection"
    assert log =~ "topic=message.events.v1"
    assert log =~ "partition=4"
    assert log =~ "committed="
    assert log =~ "earliest="
    assert log =~ "events_skipped="
    assert log =~ "2026-09-04"
  end

  test "the same recovery is live on the search consumer (shared exposure, same wrapper)" do
    {:ok, consumer_pid} = FakeConsumer.start_link(self())

    capture_log(fn ->
      assert {:noreply, _state} =
               MessageService.Events.SearchIndexConsumer.handle_info(
                 {consumer_pid, out_of_range(2)},
                 state(2)
               )
    end)

    assert_receive {:subscribed, _pid, opts}
    assert Keyword.fetch!(opts, :begin_offset) == :earliest
  end

  test "any OTHER fetch error is logged and left to brod — no resubscribe" do
    {:ok, consumer_pid} = FakeConsumer.start_link(self())

    error =
      kafka_fetch_error(
        topic: "message.events.v1",
        partition: 1,
        error_code: :leader_not_available,
        error_desc: ~c""
      )

    log =
      capture_log(fn ->
        assert {:noreply, _} =
                 MessageService.Events.InboxProjectionConsumer.handle_info(
                   {consumer_pid, error},
                   state(1)
                 )
      end)

    refute_receive {:subscribed, _, _}, 100
    assert log =~ "brod handles this one itself"
  end

  test "unrelated info messages are ignored without touching anything" do
    assert {:noreply, state} =
             MessageService.Events.InboxProjectionConsumer.handle_info(:tick, state(0))

    assert state == state(0)
    refute_receive {:subscribed, _, _}, 50
  end

  test "a dead consumer pid cannot crash the worker (recovery never turns idle into a crash loop)" do
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, _, _, _}

    log =
      capture_log(fn ->
        assert {:noreply, _} =
                 MessageService.Events.InboxProjectionConsumer.handle_info(
                   {dead, out_of_range(4)},
                   state(4)
                 )
      end)

    # brod's safe_gen_call to a dead pid returns {:error, noproc}/raises — either way the worker
    # must survive and say the partition is still stuck.
    assert log =~ "resubscribe FAILED" or log =~ "recovery raised"
  end

  # --- the liveness backstop (dropped payload connection, 2026-09-05) ------------------------------

  defmodule BrodStub do
    @moduledoc false
    def get_consumer(_client, _topic, _partition) do
      Application.get_env(:message_service, :test_current_consumer) || {:error, :unknown_topic}
    end

    def fetch_committed_offsets(_client, _group) do
      case Application.get_env(:message_service, :test_committed) do
        nil ->
          {:error, :no_broker}

        offset ->
          {:ok,
           [
             %{
               name: "message.events.v1",
               partitions: [%{partition_index: 4, committed_offset: offset}]
             }
           ]}
      end
    end

    # The partition's LOG-END offset — the other half of lag. Unset answers like an unreachable
    # broker, which is what the pre-stall-detector tests exercise (and must stay silent under).
    def resolve_offset(_endpoints, _topic, _partition, :latest) do
      case Application.get_env(:message_service, :test_log_end) do
        nil -> {:error, :no_broker}
        offset -> {:ok, offset}
      end
    end
  end

  defp with_liveness_env(fun) do
    keys = [
      :consumer_liveness_brod,
      :consumer_liveness_first_ms,
      :consumer_liveness_interval_ms,
      :consumer_stall_probes,
      :test_current_consumer,
      :test_committed,
      :test_log_end
    ]

    prev = for k <- keys, into: %{}, do: {k, Application.get_env(:message_service, k)}
    Application.put_env(:message_service, :consumer_liveness_brod, BrodStub)
    Application.put_env(:message_service, :consumer_liveness_first_ms, 20)
    Application.put_env(:message_service, :consumer_liveness_interval_ms, 60_000)

    try do
      fun.()
    after
      for {k, v} <- prev do
        if v == nil,
          do: Application.delete_env(:message_service, k),
          else: Application.put_env(:message_service, k, v)
      end
    end
  end

  defp tick(state),
    do: MessageService.Events.InboxProjectionConsumer.handle_info(:consumer_liveness_check, state)

  test "init ARMS the first liveness probe — the backstop cannot be forgotten" do
    with_liveness_env(fn ->
      {:ok, _state} =
        MessageService.Events.InboxProjectionConsumer.init(
          %{group_id: "g", topic: "message.events.v1", partition: 4},
          nil
        )

      # The tick arrives in THIS process — init runs in the worker process, and so did we.
      assert_receive :consumer_liveness_check, 500
    end)
  end

  test "first observation RECORDS the consumer pid silently; a healthy pid stays silent" do
    with_liveness_env(fn ->
      {:ok, consumer} = FakeConsumer.start_link(self())
      Application.put_env(:message_service, :test_current_consumer, {:ok, consumer})

      log =
        capture_log(fn ->
          assert {:noreply, state1} = tick(state(4))
          assert state1.known_consumer == consumer

          # Same pid on the next tick: no subscribe, no log — never a heartbeat line.
          assert {:noreply, state2} = tick(state1)
          assert state2.known_consumer == consumer
        end)

      refute_receive {:subscribed, _, _}, 50
      refute log =~ "REPLACED"
    end)
  end

  test "a REPLACED consumer is re-subscribed at the COMMITTED offset — not :earliest, not :latest" do
    with_liveness_env(fn ->
      {:ok, old} = FakeConsumer.start_link(self())
      {:ok, fresh} = FakeConsumer.start_link(self())
      Application.put_env(:message_service, :test_current_consumer, {:ok, fresh})
      Application.put_env(:message_service, :test_committed, 493)

      state = %{state(4) | known_consumer: old}

      log =
        capture_log(fn ->
          assert {:noreply, repaired} = tick(state)
          assert repaired.known_consumer == fresh
        end)

      assert_receive {:subscribed, subscriber, opts}
      assert subscriber == self()

      # THE OFFSET RULE. Committed (resume where we left off) — the out-of-range path resumes at
      # :earliest and these two must never collapse into one choice.
      assert Keyword.fetch!(opts, :begin_offset) == 493
      refute Keyword.fetch!(opts, :begin_offset) == :earliest

      assert log =~ "REPLACED"
      assert log =~ "group=message-service-inbox-projection"
      assert log =~ "topic=message.events.v1"
      assert log =~ "partition=4"
      assert log =~ "committed=493"
    end)
  end

  test "committed offset unavailable → repair DEFERRED (no subscribe, no guessed offset), retried" do
    with_liveness_env(fn ->
      {:ok, old} = FakeConsumer.start_link(self())
      {:ok, fresh} = FakeConsumer.start_link(self())
      Application.put_env(:message_service, :test_current_consumer, {:ok, fresh})
      # no :test_committed → the stub answers {:error, :no_broker}

      state = %{state(4) | known_consumer: old}

      log =
        capture_log(fn ->
          assert {:noreply, unchanged} = tick(state)
          # known stays OLD so the next tick sees the mismatch again and retries the repair.
          assert unchanged.known_consumer == old
        end)

      refute_receive {:subscribed, _, _}, 50
      assert log =~ "committed offset unavailable"
    end)
  end

  test "every tick re-arms the next probe — the loop survives a repair" do
    with_liveness_env(fn ->
      Application.put_env(:message_service, :consumer_liveness_interval_ms, 30)
      {:ok, consumer} = FakeConsumer.start_link(self())
      Application.put_env(:message_service, :test_current_consumer, {:ok, consumer})

      capture_log(fn ->
        assert {:noreply, _} = tick(state(4))
      end)

      assert_receive :consumer_liveness_check, 500
    end)
  end

  # --- the stall detector (same pid, offsets in range, no progress — 2026-09-06) -------------------

  defmodule RefusingConsumer do
    @moduledoc false
    # brod's answer when ANOTHER process holds the one subscriber slot this consumer has
    # (brod_consumer.erl:445) — the shape the shared-client contention wedge produces.
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call({:subscribe, subscriber_pid, opts}, _from, test_pid) do
      send(test_pid, {:subscribe_refused, subscriber_pid, opts})
      {:reply, {:error, {:already_subscribed_by, self()}}, test_pid}
    end
  end

  # A partition sitting at `committed` with the log ending at `log_end`, consumer pid unchanged.
  defp stalled_at(committed, log_end) do
    {:ok, consumer} = FakeConsumer.start_link(self())
    Application.put_env(:message_service, :test_current_consumer, {:ok, consumer})
    Application.put_env(:message_service, :test_committed, committed)
    Application.put_env(:message_service, :test_log_end, log_end)
    # Start PAST the first observation: the pid is already known, so every tick below is the
    # same-pid path — exactly the state the 2026-09-06 partition was wedged in.
    {consumer, %{state(4) | known_consumer: consumer}}
  end

  defp probe(state) do
    {:noreply, next} = tick(state)
    next
  end

  test "ZERO LAG is never touched: a caught-up partition sits for twice the window in silence" do
    with_liveness_env(fn ->
      # committed == log_end: nothing to consume. Indistinguishable from a wedge by offsets alone,
      # which is exactly why lag — not stillness — is the trigger.
      {_consumer, state} = stalled_at(353, 353)

      log =
        capture_log(fn ->
          Enum.reduce(1..6, state, fn _, acc -> probe(acc) end)
        end)

      refute_receive {:subscribed, _, _}, 100
      refute log =~ "STALLED"
      assert log == "" or not (log =~ "kafka consumer")
    end)
  end

  test "THREE consecutive frozen probes are required — the baseline and the next two act silently" do
    with_liveness_env(fn ->
      {_consumer, state} = stalled_at(353, 359)

      log =
        capture_log(fn ->
          # 1: baseline (first measurement on this subscription). 2: stalled=1. 3: stalled=2.
          state = state |> probe() |> probe() |> probe()

          refute_receive {:subscribed, _, _}, 100
          refute_received {:subscribed, _, _}

          # 4: stalled=3 → the threshold, and only now.
          _ = probe(state)
        end)

      assert_receive {:subscribed, _pid, _opts}
      assert log =~ "STALLED"
    end)
  end

  test "the stall repair resubscribes at the COMMITTED offset — not :earliest, not :latest" do
    with_liveness_env(fn ->
      {_consumer, state} = stalled_at(353, 359)

      capture_log(fn ->
        Enum.reduce(1..4, state, fn _, acc -> probe(acc) end)
      end)

      assert_receive {:subscribed, subscriber, opts}
      assert subscriber == self()

      # THE OFFSET RULE, third branch. Committed resumes exactly the unprocessed tail; :earliest is
      # the out-of-range branch's choice and would replay the partition; :latest would skip the
      # very events this lag is made of.
      assert Keyword.fetch!(opts, :begin_offset) == 353
      refute Keyword.fetch!(opts, :begin_offset) == :earliest
      refute Keyword.fetch!(opts, :begin_offset) == :latest
      refute Keyword.fetch!(opts, :begin_offset) == 359
    end)
  end

  test "SAME PID, lag > 0, committed frozen → repaired, and the log quantifies the wedge" do
    with_liveness_env(fn ->
      {consumer, state} = stalled_at(353, 359)

      log =
        capture_log(fn ->
          Enum.reduce(1..4, state, fn _, acc -> probe(acc) end)
        end)

      assert_receive {:subscribed, _pid, _opts}

      # Loud, named and quantified — the whole point is that this state produced NO log line at all.
      assert log =~ "STALLED"
      assert log =~ "group=message-service-inbox-projection"
      assert log =~ "topic=message.events.v1"
      assert log =~ "partition=4"
      assert log =~ "committed=353"
      assert log =~ "log_end=359"
      assert log =~ "lag=6"
      assert log =~ "stalled_for="
      assert log =~ inspect(consumer)
    end)
  end

  test "PROGRESS resets the counter — a partition that keeps committing is never repaired" do
    with_liveness_env(fn ->
      {_consumer, state} = stalled_at(353, 400)

      log =
        capture_log(fn ->
          Enum.reduce(1..8, {state, 353}, fn _, {acc, committed} ->
            # Each probe sees a committed offset one higher: slow, but moving.
            Application.put_env(:message_service, :test_committed, committed + 1)
            {probe(acc), committed + 1}
          end)
        end)

      refute_receive {:subscribed, _, _}, 100
      refute log =~ "STALLED"
    end)
  end

  test "an UNMEASURABLE partition (no committed / no log-end) is never repaired and never logs" do
    with_liveness_env(fn ->
      {_consumer, state} = stalled_at(353, 359)

      for missing <- [:test_committed, :test_log_end] do
        Application.delete_env(:message_service, missing)

        log =
          capture_log(fn ->
            Enum.reduce(1..5, state, fn _, acc -> probe(acc) end)
          end)

        refute_receive {:subscribed, _, _}, 50
        refute log =~ "STALLED"

        Application.put_env(:message_service, :test_committed, 353)
        Application.put_env(:message_service, :test_log_end, 359)
      end
    end)
  end

  test "a REFUSED resubscribe (another group holds the slot) logs the holder and retries a window later" do
    with_liveness_env(fn ->
      {:ok, refusing} = RefusingConsumer.start_link(self())
      Application.put_env(:message_service, :test_current_consumer, {:ok, refusing})
      Application.put_env(:message_service, :test_committed, 353)
      Application.put_env(:message_service, :test_log_end, 359)
      state = %{state(4) | known_consumer: refusing}

      log =
        capture_log(fn ->
          state = Enum.reduce(1..4, state, fn _, acc -> probe(acc) end)

          # Exactly ONE attempt in the first window.
          assert_receive {:subscribe_refused, _pid, _opts}
          refute_received {:subscribe_refused, _, _}

          # The counter restarts: no second attempt until another full window has passed.
          state = state |> probe() |> probe()
          refute_received {:subscribe_refused, _, _}

          _ = probe(state)
          assert_receive {:subscribe_refused, _, _}
        end)

      assert log =~ "resubscribe FAILED"
      assert log =~ "already_subscribed_by"
    end)
  end

  test "the stall detector is live on the OTHER consumers too — all four share this backstop" do
    with_liveness_env(fn ->
      {_consumer, state} = stalled_at(353, 359)

      capture_log(fn ->
        Enum.reduce(1..4, state, fn _, acc ->
          {:noreply, next} =
            MessageService.Events.SearchIndexConsumer.handle_info(:consumer_liveness_check, acc)

          next
        end)
      end)

      assert_receive {:subscribed, _pid, opts}
      assert Keyword.fetch!(opts, :begin_offset) == 353
    end)
  end

  test "a probe failure never crashes the worker and keeps the loop armed" do
    with_liveness_env(fn ->
      Application.put_env(:message_service, :consumer_liveness_interval_ms, 30)
      # get_consumer answers {:error, ...} (the stub default with no :test_current_consumer)

      log =
        capture_log(fn ->
          assert {:noreply, state} = tick(state(4))
          assert state.known_consumer == nil
        end)

      assert log =~ "LIVENESS probe failed"
      assert_receive :consumer_liveness_check, 500
    end)
  end
end
