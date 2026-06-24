defmodule MessageService.Events.MessageCreatedLogConsumer do
  @moduledoc """
  Minimal `brod_group_subscriber_v2` that consumes `message.events.v1`, logs each
  event, and commits the offset. Proves the Kafka pipe end-to-end with NO behavior
  coupling — log/ack only, no DB writes, no fanout, no side effects. Started ONLY
  under `KAFKA_CONSUMER_ENABLED` (see `MessageService.Application`).

  Delivery is at-least-once (brod commits AFTER handling). This consumer is safe
  because it has no side effects (logging is idempotent). CARRIED-FORWARD CONSTRAINT:
  any future STATEFUL consumer (projections / fanout / notifications) MUST dedupe on
  the envelope `event_id` (present in the envelope) or use idempotent upserts.
  """

  @behaviour :brod_group_subscriber_v2

  require Logger
  require Record

  Record.defrecordp(
    :kafka_message,
    Record.extract(:kafka_message, from_lib: "kafka_protocol/include/kpro_public.hrl")
  )

  @impl true
  def init(_init_info, init_data), do: {:ok, init_data}

  @impl true
  def handle_message(message, state) do
    handle(
      kafka_message(message, :key),
      kafka_message(message, :value),
      kafka_message(message, :offset)
    )

    # Always commit — even a poison/undecodable message is logged and skipped so it
    # cannot wedge the partition (no crash-loop).
    {:ok, :commit, state}
  end

  defp handle(key, value, offset) do
    case Jason.decode(value) do
      {:ok, %{"event_type" => event_type} = envelope} ->
        # Carry the originating request's id so this consumer's logs join the same trace.
        SharedInfra.Correlation.put(envelope["correlation_id"])

        Logger.info(
          "kafka consume #{event_type} key=#{inspect(key)} offset=#{offset} " <>
            "event_id=#{inspect(envelope["event_id"])}"
        )

        notify_test({:kafka_consumed, envelope, key, offset})

      {:ok, _decoded} ->
        Logger.info("kafka consume (no event_type) key=#{inspect(key)} offset=#{offset}")

      {:error, reason} ->
        Logger.warning("kafka consume: JSON decode failed offset=#{offset}: #{inspect(reason)}")
    end
  rescue
    error ->
      Logger.warning("kafka consume handler raised, committing anyway: #{inspect(error)}")
  end

  # Test hook: forward handled events to a configured test pid (set in the
  # kafka_integration test). No-op in normal operation.
  defp notify_test(payload) do
    case Application.get_env(:message_service, :kafka_consumer_test_pid) do
      pid when is_pid(pid) ->
        send(pid, payload)
        # Regression guard: proves correlation_id reached this consumer process's Logger metadata.
        send(pid, {:consumer_correlation, SharedInfra.Correlation.get()})

      _ ->
        :ok
    end
  end
end
