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
  # redeliver-forever).
  #
  # REPLACED, because the old wording was the bug: it read "Any other error (transient DB) → retry
  # (do NOT commit)", which assumes every non-invalid_event error is transient. It is not. A
  # permanent error — a type mismatch, a constraint violation, a shape the code cannot handle —
  # retries forever and WEDGES THE PARTITION, silently. See the poison clause below.
  # PUBLIC (@doc false) so the classification can be asserted directly. It is a pure function of the
  # apply result; testing it through handle_message would require stubbing the projection and a DB,
  # and would test the plumbing rather than the decision that wedges partitions when it is wrong.
  @doc false
  def commit_decision({:ok, :applied}, _offset), do: :commit
  def commit_decision({:ok, :duplicate}, _offset), do: :commit

  def commit_decision({:error, :invalid_event}, offset) do
    Logger.warning("notification: invalid event offset=#{offset}, skipping (commit)")
    :commit
  end

  # POISON: errors that CANNOT succeed on retry. Retrying them wedges the partition forever —
  # nothing behind the stuck offset is ever processed — which is worse than dropping one event.
  # Observed for real in the sibling inbox consumer: a %DBConnection.EncodeError% (a type mismatch
  # between a store response and a Postgres write) retried one offset indefinitely.
  #
  #   Postgrex.Error   — a constraint/syntax/type failure on OUR statement; identical every time.
  #   ArgumentError / FunctionClauseError / KeyError / MatchError
  #                    — a shape the code cannot handle; deterministic in the event's content.
  #
  # Still transient, because these CAN succeed later:
  #   DBConnection.ConnectionError — pool down or timed out; retry is exactly right.
  def commit_decision({:error, %struct{}}, offset)
      when struct in [
             DBConnection.EncodeError,
             Postgrex.Error,
             ArgumentError,
             FunctionClauseError,
             KeyError,
             MatchError
           ] do
    Logger.error(
      "notification: POISON event offset=#{offset} (#{inspect(struct)}) — committing to skip. " <>
        "This is a code defect, not a transient failure; the event has been DROPPED."
    )

    :commit
  end

  def commit_decision({:error, reason}, offset) do
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
