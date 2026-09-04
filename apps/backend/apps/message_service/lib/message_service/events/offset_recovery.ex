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
    %{
      group_id: Map.get(init_info, :group_id),
      topic: Map.get(init_info, :topic),
      partition: Map.get(init_info, :partition),
      inner: inner
    }
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

  # --- best-effort offset lookups (log-enrichment only — recovery proceeds without them) -----------

  defp committed_offset(group, topic, partition) do
    case :brod.fetch_committed_offsets(SharedInfra.Kafka.BrodProducer.client_name(), group) do
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
