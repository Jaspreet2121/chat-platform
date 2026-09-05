defmodule MessageService.Events.OffsetRecovery do
  @moduledoc """
  Recovery for the ONE fetch error brod will not recover from on its own: `offset_out_of_range`.

  ## The wedge this exists for (observed in production, 2026-09-04)

  The inbox-projection consumer group sat idle for ~7 hours because partition 4's COMMITTED offset
  (165) was below that partition's EARLIEST available offset (219) — the broker answers every fetch
  with OffsetOutOfRange. Why 165–219 were gone despite a persistent volume and 7-day retention was
  never explained; this module treats "a committed offset can fall out of range" as a condition to
  SURVIVE, not one to prevent.

  What brod does with it, mechanically (brod 4.5.5):

    * `brod_consumer` maps the error to `reset_offset` (brod_consumer.erl:674). Under the DEFAULT
      `offset_reset_policy = reset_by_subscriber` (:198-200) it casts
      `{ConsumerPid, #kafka_fetch_error{}}` to the subscriber, logs at INFO only, sets
      `is_suspended = true` and stops fetching (:716-723) — waiting for the subscriber to
      resubscribe with a new begin_offset.
    * The subscriber is the group worker's `brod_topic_subscriber`. Its `handle_info` matches only
      `#kafka_message_set{}`; the error tuple falls through to the CALLBACK module's OPTIONAL
      `handle_info/2` (brod_topic_subscriber.erl:379-386). Our consumers did not export it, so
      `brod_utils:optional_callback` swallowed the message with a default `{noreply, State}`.
    * The 2s resubscribe timer cannot help: a suspended consumer's pid is still ALIVE, so
      `subscribe_partition` hits its "already subscribed" clause and skips it
      (brod_topic_subscriber.erl "is_pid_alive → true"). The suspension is permanent and SILENT —
      no exception, no error log, no commit, and sibling partitions queue behind the connection.

  So the smallest correct seat for recovery is exactly the hook brod designed for it: the callback's
  `handle_info/2`, which runs IN the worker process — the registered subscriber — so it may
  legitimately call `:brod.subscribe(consumer_pid, self(), ...)` to clear the suspension
  (brod_consumer accepts a re-subscribe from the same pid and resets `is_suspended` — :433, :831).

  ## Policy: EARLIEST, never latest

  Resuming at :earliest skips only what the broker has already deleted — the least possible loss.
  Resuming at :latest would additionally discard every event the broker still holds. The projection
  side is safe under replay either way (`processed_events` ledger + `inbox_read_marks` claims), so
  the only correct choice is the one that loses the least.

  Every recovery logs at ERROR with the group, topic, partition, the committed and earliest offsets
  (best-effort — resolved out-of-band, `:unknown` when unreachable) and the derived skipped count,
  so the gap is visible and quantified even though the consumer no longer sits on it.

  ## The SECOND wedge: a dropped payload connection (2026-09-05, twice in 24h — broker innocent)

  brod logs `payload connection down ... {:shutdown, :tcp_closed}` and reconnects ~5 minutes later;
  afterwards SOME partitions never resume — committed offset frozen, lag growing, no exception, no
  log line, group membership intact. The broker was healthy both times (2 months uptime, zero
  restarts, every rebalance in its log maps to one of our deploys); the socket died client-side.

  What the source says happens (brod 4.5.5):

    * `brod_consumer` SURVIVES the connection death — `handle_conn_down` clears the connection and
      loops `?INIT_CONNECTION` until the client reconnects (brod_consumer.erl:509-512, :382-401),
      then clears the orphaned in-flight request ref and resumes (:936-941). That is the designed
      self-heal, and it is why SOME partitions come back on their own.
    * A consumer that dies anyway (they are `{permanent, 2s}` children — brod_consumers_sup.erl:42,
      :136) comes back FRESH and unsubscribed. The worker's monitor marks it ?DOWN
      (brod_topic_subscriber.erl:365-377) and the 2s resubscribe loop repairs it — EXCEPT when
      `AckedOffset =/= LastOffset` (a delivery our wrapper deliberately did NOT ack, i.e. the
      `:retry` no-commit path for a transient DB error): `subscribe_partition`'s carve-out then
      skips the partition "for now", and since the redelivery that would close the gap can only
      come from the dead consumer, "for now" is FOREVER.
    * In every variant, NOTHING reaches this callback: consumer 'DOWN's are consumed by the
      worker's own handle_info clause BEFORE the callback catch-all
      (brod_topic_subscriber.erl:365-377 vs :379-386), and fetch errors only arise from received
      responses — a dead socket produces none.

  So this module also runs a LIVENESS BACKSTOP in each worker: a periodic self-message (armed in
  `init_state/2`, running in the worker process) probes the client's CURRENT consumer pid for the
  partition. A changed pid means the consumer was replaced and this worker may no longer be
  subscribed; the repair re-subscribes at the group's COMMITTED offset. Quiet when healthy — it
  logs at ERROR only when it actually repairs (or cannot).

  ## Committed for the connection path, EARLIEST for the out-of-range path — never collapse these

  The two recoveries resume from DIFFERENT offsets, deliberately. Out-of-range means the committed
  position NO LONGER EXISTS on the broker, so `:earliest` loses the least. A replaced consumer's
  committed offset is perfectly valid — resuming there redelivers exactly the unprocessed tail
  (including any un-acked `:retry` batch, which is precisely what retry wanted) and nothing else.
  `:earliest` here would replay the whole retained partition for no reason; `:latest` would skip
  real events. A future refactor that unifies them on one offset choice breaks one path or the
  other — MUT-3 in the tests exists to catch exactly that.
  """

  require Logger
  require Record

  Record.defrecordp(
    :kafka_fetch_error,
    Record.extract(:kafka_fetch_error, from_lib: "brod/include/brod.hrl")
  )

  @doc """
  Build the callback state each consumer keeps: the identity brod hands to `init/2` (group, topic,
  partition), which `handle_fetch_error/2` needs to name the partition it is recovering.
  """
  def init_state(init_info, inner) do
    # The first probe fires FAST (default 5s) so a consumer replaced during the boot window is
    # caught quickly; steady state is the conservative interval. Armed HERE because init/2 runs in
    # the worker process — the same process brod forwards unknown infos to, so the tick lands in
    # handle_info/2 below.
    Process.send_after(self(), :consumer_liveness_check, liveness_first_ms())

    %{
      group_id: Map.get(init_info, :group_id),
      topic: Map.get(init_info, :topic),
      partition: Map.get(init_info, :partition),
      known_consumer: nil,
      inner: inner
    }
  end

  @doc """
  Route a message forwarded to the callback's `handle_info/2`. Returns the (possibly updated)
  callback state — consumers must thread it back, not discard it: the liveness probe's memory of
  the current consumer pid lives here.
  """
  def handle_info(:consumer_liveness_check, state) do
    liveness_check(state)
  end

  def handle_info(info, state) do
    handle_fetch_error(info, state)
    state
  end

  @doc """
  Handle a message forwarded to the callback's `handle_info/2`.

  Recovers `offset_out_of_range` by resubscribing THIS worker to the consumer at `:earliest`. Any
  other fetch error is logged and left to brod (its `err_op` handles them with retry / reconnect /
  restart on its own). Anything else is ignored. Always returns the state unchanged — recovery never
  crashes the worker: a raise here would restart it into the same out-of-range fetch, a crash loop
  where today's code merely sat idle.
  """
  def handle_fetch_error({consumer_pid, error}, state) when is_pid(consumer_pid) do
    case error do
      kafka_fetch_error(topic: topic, partition: partition, error_code: :offset_out_of_range) ->
        recover(consumer_pid, topic, partition, state)

      kafka_fetch_error(topic: topic, partition: partition, error_code: code) ->
        Logger.warning(
          "kafka consumer fetch error (brod handles this one itself) " <>
            "group=#{state[:group_id]} topic=#{topic} partition=#{partition} code=#{inspect(code)}"
        )

        :ok

      _ ->
        :ok
    end
  end

  def handle_fetch_error(_info, _state), do: :ok

  defp recover(consumer_pid, topic, partition, state) do
    group = state[:group_id]
    committed = committed_offset(group, topic, partition)
    earliest = earliest_offset(topic, partition)

    Logger.error(
      "kafka consumer OFFSET OUT OF RANGE — committed position no longer exists on the broker. " <>
        "group=#{group} topic=#{topic} partition=#{partition} " <>
        "committed=#{inspect(committed)} earliest=#{inspect(earliest)} " <>
        "events_skipped=#{inspect(skipped(committed, earliest))}. " <>
        "Resubscribing at :earliest so the partition resumes instead of suspending. " <>
        "(2026-09-04: this exact condition idled the inbox projection for ~7h, silently — " <>
        "committed 165 < earliest 219 on partition 4, cause of the gap never established.)"
    )

    case :brod.subscribe(consumer_pid, self(), begin_offset: :earliest) do
      :ok ->
        :ok

      {:error, reason} ->
        # The 2s LO_CMD_SUBSCRIBE_PARTITIONS loop retries a DEAD consumer; only a suspended-alive one
        # needs us. If even the resubscribe fails, log loudly — this partition is still stuck.
        Logger.error(
          "kafka consumer resubscribe FAILED — partition still suspended. " <>
            "group=#{group} topic=#{topic} partition=#{partition} reason=#{inspect(reason)}"
        )

        :error
    end
  rescue
    error ->
      Logger.error(
        "kafka consumer offset recovery raised (partition may still be suspended) " <>
          "group=#{state[:group_id]} topic=#{topic} partition=#{partition}: #{inspect(error)}"
      )

      :error
  end

  # --- the liveness backstop (the dropped-connection wedge, 2026-09-05) ----------------------------

  defp liveness_check(state) do
    # Re-arm FIRST — the loop must survive anything the probe does.
    Process.send_after(self(), :consumer_liveness_check, liveness_interval_ms())

    %{group_id: group, topic: topic, partition: partition, known_consumer: known} = state

    case brod_api().get_consumer(SharedInfra.Kafka.BrodProducer.client_name(), topic, partition) do
      {:ok, ^known} ->
        # Healthy: the consumer we last confirmed is still the one registered. Deliberately silent —
        # this fires every interval on every partition and must never be a heartbeat log line.
        state

      {:ok, current} when known == nil ->
        # First observation after (re)init. The worker's own init subscribe targeted this same pid
        # via the same client, so record it and say nothing.
        %{state | known_consumer: current}

      {:ok, current} ->
        # THE CONSUMER WAS REPLACED under us. The fresh one may already have been re-subscribed by
        # the worker's 2s loop (the acked==last case) — our re-subscribe is then an idempotent
        # position refresh to the same offset. In the frozen case (an un-acked :retry delivery when
        # the old consumer died) the 2s loop is skipping this partition FOREVER and this is the only
        # repair there is.
        repair_subscription(state, current)

      {:error, reason} ->
        Logger.error(
          "kafka consumer LIVENESS probe failed (will retry next interval) " <>
            "group=#{group} topic=#{topic} partition=#{partition} reason=#{inspect(reason)}"
        )

        state
    end
  rescue
    error ->
      Logger.error(
        "kafka consumer liveness check raised (backstop still armed) " <>
          "group=#{state[:group_id]} topic=#{state[:topic]} partition=#{state[:partition]}: " <>
          inspect(error)
      )

      state
  end

  defp repair_subscription(state, current) do
    %{group_id: group, topic: topic, partition: partition, known_consumer: known} = state

    # COMMITTED, not :earliest, not :latest — see the moduledoc. The committed offset is REQUIRED
    # here (unlike the out-of-range path, where it is log enrichment): guessing a position would
    # either replay the partition or skip real events, so an unfetchable committed offset defers
    # the repair to the next interval instead.
    case committed_offset(group, topic, partition) do
      committed when is_integer(committed) and committed >= 0 ->
        case :brod.subscribe(current, self(), begin_offset: committed) do
          :ok ->
            Logger.error(
              "kafka consumer REPLACED — resubscribed at the committed offset. " <>
                "group=#{group} topic=#{topic} partition=#{partition} " <>
                "committed=#{committed} consumer=#{inspect(known)} -> #{inspect(current)}. " <>
                "(Liveness backstop: payload-connection wedge, seen 2026-09-04/05; " <>
                "the worker's own resubscribe loop skips a partition with un-acked deliveries.)"
            )

            %{state | known_consumer: current}

          {:error, reason} ->
            Logger.error(
              "kafka consumer REPLACED but resubscribe FAILED (will retry next interval) " <>
                "group=#{group} topic=#{topic} partition=#{partition} reason=#{inspect(reason)}"
            )

            state
        end

      other ->
        Logger.error(
          "kafka consumer REPLACED but committed offset unavailable (#{inspect(other)}) — " <>
            "deferring repair to the next interval. group=#{group} topic=#{topic} " <>
            "partition=#{partition}"
        )

        state
    end
  end

  defp liveness_first_ms,
    do: Application.get_env(:message_service, :consumer_liveness_first_ms, 5_000)

  defp liveness_interval_ms,
    do: Application.get_env(:message_service, :consumer_liveness_interval_ms, 60_000)

  # Seam for tests: get_consumer must be stubbable (there is no brod client in unit tests).
  defp brod_api,
    do: Application.get_env(:message_service, :consumer_liveness_brod, __MODULE__.RealBrod)

  defmodule RealBrod do
    @moduledoc false
    defdelegate get_consumer(client, topic, partition), to: :brod
    defdelegate fetch_committed_offsets(client, group), to: :brod
  end

  # --- best-effort offset lookups (log-enrichment only — recovery proceeds without them) -----------

  defp committed_offset(group, topic, partition) do
    case brod_api().fetch_committed_offsets(SharedInfra.Kafka.BrodProducer.client_name(), group) do
      {:ok, topics} ->
        topics
        |> Enum.find(%{}, &(name_of(&1) == topic))
        |> partitions_of()
        |> Enum.find(%{}, &(index_of(&1) == partition))
        |> Map.get(:committed_offset, :unknown)

      _ ->
        :unknown
    end
  rescue
    _ -> :unknown
  end

  defp earliest_offset(topic, partition) do
    case :brod.resolve_offset(endpoints(), topic, partition, :earliest) do
      {:ok, offset} -> offset
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  end

  defp skipped(committed, earliest) when is_integer(committed) and is_integer(earliest),
    do: max(earliest - committed, 0)

  defp skipped(_committed, _earliest), do: :unknown

  # kpro answers arrive as maps whose key style varies by protocol version — read defensively.
  defp name_of(t), do: Map.get(t, :name) || Map.get(t, :topic)
  defp partitions_of(t), do: Map.get(t, :partitions) || Map.get(t, :partition_responses) || []
  defp index_of(p), do: Map.get(p, :partition_index) || Map.get(p, :partition)

  # Same "host:port,host:port" string application.ex parses for the subscribers themselves.
  defp endpoints do
    :message_service
    |> Application.get_env(:kafka, [])
    |> Keyword.get(:brokers, "localhost:9094")
    |> String.split(",", trim: true)
    |> Enum.map(fn endpoint ->
      case String.split(endpoint, ":", parts: 2) do
        [host, port] -> {String.to_charlist(host), String.to_integer(port)}
        [host] -> {String.to_charlist(host), 9092}
      end
    end)
  end
end
