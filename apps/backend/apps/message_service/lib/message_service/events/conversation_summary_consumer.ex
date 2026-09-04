defmodule MessageService.Events.ConversationSummaryConsumer do
  @moduledoc """
  Stateful, idempotent `brod_group_subscriber_v2` consumer for `message.events.v1`.

  Maintains the per-conversation summary projection via
  `MessageService.Projections.ConversationSummary.apply_message_created/1` (deduped by
  event_id). Started ONLY under `KAFKA_PROJECTION_CONSUMER_ENABLED` in a DISTINCT group
  (`message-service-conversation-summary`) so its offsets/processing are independent of
  the log consumer.

  Commit ordering (at-least-once): the DB work runs FIRST; we commit the offset only on
  success (applied/duplicate). A transient DB error returns `{:ok, state}` (NO commit) so
  the event is redelivered and retried. A structurally invalid or undecodable (poison)
  event is logged and committed (skipped) so it cannot wedge the partition.
  """

  @behaviour :brod_group_subscriber_v2

  require Logger
  require Record

  alias MessageService.Projections.ConversationSummary

  Record.defrecordp(
    :kafka_message,
    Record.extract(:kafka_message, from_lib: "kafka_protocol/include/kpro_public.hrl")
  )

  @impl true
  def init(init_info, init_data),
    do: {:ok, MessageService.Events.OffsetRecovery.init_state(init_info, init_data)}

  # THE OPTIONAL CALLBACK THAT UN-WEDGES offset_out_of_range. Without it, brod's fetch-error cast is
  # swallowed by brod_utils:optional_callback's default and the partition stays suspended forever —
  # the 2026-09-04 seven-hour inbox outage. See MessageService.Events.OffsetRecovery.
  #
  # NO @impl: brod_group_subscriber_v2 does not DECLARE handle_info/2 — the worker dispatches it via
  # brod_utils:optional_callback (brod_group_subscriber_worker.erl:96), so an @impl would be a
  # compile warning (an error under --warnings-as-errors).
  def handle_info(info, state) do
    MessageService.Events.OffsetRecovery.handle_fetch_error(info, state)
    {:noreply, state}
  end

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
        result = ConversationSummary.apply_message_created(envelope)
        notify_test(envelope, result)
        commit_decision(result, offset)

      {:error, reason} ->
        # Poison/undecodable → log + commit (skip; never wedge the partition).
        Logger.warning(
          "conversation-summary: JSON decode failed offset=#{offset}, skipping: #{inspect(reason)}"
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
  defp commit_decision({:ok, :applied}, _offset), do: :commit
  defp commit_decision({:ok, :duplicate}, _offset), do: :commit

  defp commit_decision({:error, :invalid_event}, offset) do
    Logger.warning("conversation-summary: invalid event offset=#{offset}, skipping (commit)")
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
  defp commit_decision({:error, %struct{}}, offset)
       when struct in [
              DBConnection.EncodeError,
              Postgrex.Error,
              ArgumentError,
              FunctionClauseError,
              KeyError,
              MatchError
            ] do
    Logger.error(
      "conversation-summary: POISON event offset=#{offset} (#{inspect(struct)}) — committing to skip. " <>
        "This is a code defect, not a transient failure; the event has been DROPPED."
    )

    :commit
  end

  defp commit_decision({:error, reason}, offset) do
    Logger.warning(
      "conversation-summary: apply failed offset=#{offset}, NOT committing (retry): #{inspect(reason)}"
    )

    :retry
  end

  defp notify_test(envelope, result) do
    case Application.get_env(:message_service, :conversation_summary_test_pid) do
      pid when is_pid(pid) ->
        conversation_id = envelope |> Map.get("payload", %{}) |> Map.get("conversation_id")
        send(pid, {:conversation_summary_applied, conversation_id, result})
        # Regression guard: proves correlation_id reached this consumer process's Logger metadata.
        send(pid, {:consumer_correlation, SharedInfra.Correlation.get()})

      _ ->
        :ok
    end
  end
end
