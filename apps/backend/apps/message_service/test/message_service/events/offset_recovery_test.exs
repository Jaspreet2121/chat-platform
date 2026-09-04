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
end
