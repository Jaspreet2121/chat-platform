defmodule NotificationService.Events.MessageCreatedConsumer do
  @moduledoc """
  Stateful, idempotent `brod_group_subscriber_v2` consumer for `message.events.v1`.

  Creates ONE notification per `message.created.v1` via
  `NotificationService.Notifications.apply_message_created/1` (deduped by event_id in
  notification-service's own ledger). Runs in a DISTINCT group
  (`notification-service-message-created`) so its offsets/processing are independent of
  message-service's consumers on the same topic.

  Commit ordering (at-least-once): the DB work runs FIRST; we commit the offset only on
  success (applied/duplicate). A transient DB error returns `{:ok, state}` (NO commit) so
  the event is redelivered and retried. A structurally invalid or undecodable (poison)
  event is logged and committed (skipped) so it cannot wedge the partition.
  """

  @behaviour :brod_group_subscriber_v2

  require Logger
  require Record

  alias NotificationService.Notifications

  Record.defrecordp(
    :kafka_message,
    Record.extract(:kafka_message, from_lib: "kafka_protocol/include/kpro_public.hrl")
  )

  @impl true
  def init(_init_info, init_data), do: {:ok, init_data}

  @impl true
  def handle_message(message, state) do
    value = kafka_message(message, :value)
    offset = kafka_message(message, :offset)

    case decode_and_apply(value, offset) do
      :commit -> {:ok, :commit, state}
      :retry -> {:ok, state}
    end
  end

  defp decode_and_apply(value, offset) do
    case Jason.decode(value) do
      {:ok, envelope} when is_map(envelope) ->
        # Carry the originating request's id so this consumer's logs join the same trace.
        SharedInfra.Correlation.put(envelope["correlation_id"])
        result = Notifications.apply_message_created(envelope)
        notify_test(envelope, result)
        commit_decision(result, offset)

      {:error, reason} ->
        # Poison/undecodable → log + commit (skip; never wedge the partition).
        Logger.warning(
          "notification: JSON decode failed offset=#{offset}, skipping: #{inspect(reason)}"
        )

        :commit
    end
  end

  # applied/duplicate → commit. invalid_event (structurally bad) → commit (skip, no
  # redeliver-forever). Any other error (transient DB) → retry (do NOT commit).
  defp commit_decision({:ok, :applied}, _offset), do: :commit
  defp commit_decision({:ok, :duplicate}, _offset), do: :commit

  defp commit_decision({:error, :invalid_event}, offset) do
    Logger.warning("notification: invalid event offset=#{offset}, skipping (commit)")
    :commit
  end

  defp commit_decision({:error, reason}, offset) do
    Logger.warning(
      "notification: apply failed offset=#{offset}, NOT committing (retry): #{inspect(reason)}"
    )

    :retry
  end

  defp notify_test(envelope, result) do
    case Application.get_env(:notification_service, :notification_test_pid) do
      pid when is_pid(pid) ->
        send(pid, {:notification_applied, Map.get(envelope, "event_id"), result})
        # Regression guard: proves correlation_id was extracted into THIS consumer process's
        # Logger metadata (Correlation.put/1 ran above). Asserted by the kafka_integration test.
        send(pid, {:consumer_correlation, SharedInfra.Correlation.get()})

      _ ->
        :ok
    end
  end
end
