defmodule MessageService.Events.InboxProjectionConsumer do
  @moduledoc """
  Stateful, idempotent `brod_group_subscriber_v2` consumer for `message.events.v1`, maintaining the
  denormalised INBOX ROW (086) via `MessageService.Projections.InboxFromTopic`.

  Started ONLY under `KAFKA_INBOX_CONSUMER_ENABLED`, in a DISTINCT group
  (`message-service-inbox-projection`) so its offsets and failures are independent of the
  conversation-summary and log consumers on the same topic. Copied from
  `ConversationSummaryConsumer` rather than extended — see the projection's moduledoc for why.

  Unlike that consumer this one handles TWO event types (`message.created.v1` and
  `message.deleted.v1`) and routes on `event_type`; anything else commits as ignored.

  Commit ordering (at-least-once), same contract as the model: DB work runs FIRST and the offset is
  committed only on success. A transient DB error returns `{:ok, state}` with NO commit so the event
  is redelivered; a structurally invalid or undecodable event is logged and committed so it cannot
  wedge the partition.

  WHY THIS IS SAFE TO ENABLE BEFORE THE CUTOVER: the projection self-gates on the store adapter and
  returns `:skipped_postgres_adapter` while `MessageService.MessageStore.PostgresAdapter` is
  selected, because that adapter already maintains these columns inside the message transaction.
  Running both writers would double every unread increment.
  """

  @behaviour :brod_group_subscriber_v2

  require Logger
  require Record

  alias MessageService.Projections.InboxFromTopic

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
        result = InboxFromTopic.apply_event(envelope)
        notify_test(envelope, result)
        commit_decision(result, offset)

      {:error, reason} ->
        Logger.warning(
          "inbox-projection: JSON decode failed offset=#{offset}, skipping: #{inspect(reason)}"
        )

        :commit
    end
  end

  # Every non-error outcome commits, including the ones that wrote nothing: a duplicate is already
  # applied, an absent message no longer exists, an ignored type is not ours, and the
  # postgres-adapter skip means the in-transaction writer is doing this work instead. Redelivering
  # any of them would change nothing.
  defp commit_decision({:ok, _outcome}, _offset), do: :commit

  defp commit_decision({:error, :invalid_event}, offset) do
    Logger.warning("inbox-projection: invalid event offset=#{offset}, skipping (commit)")
    :commit
  end

  # POISON: errors that CANNOT succeed on retry. Retrying them wedges the partition forever, which is
  # a worse outcome than dropping one event — nothing behind the stuck offset is ever processed.
  # Observed for real: a %DBConnection.EncodeError% (a type mismatch between the store's response and
  # the projection's write) retried offset 8 indefinitely and blocked the whole partition.
  #
  #   Postgrex.Error   — a constraint/syntax/type failure on OUR statement. The same event will fail
  #                      the same way every time; only a code change fixes it.
  #   ArgumentError / FunctionClauseError / KeyError / MatchError
  #                    — a shape the code cannot handle. Deterministic in the event's content.
  #
  # Deliberately NOT poison, because these CAN succeed later:
  #   DBConnection.ConnectionError — the pool is down or timed out; retry is exactly right.
  #   :message_store_unavailable   — the store is unreachable; the message may exist later.
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
      "inbox-projection: POISON event offset=#{offset} (#{inspect(struct)}) — committing to skip. " <>
        "This is a code defect, not a transient failure; the projection has DROPPED this event."
    )

    :commit
  end

  defp commit_decision({:error, reason}, offset) do
    Logger.warning(
      "inbox-projection: apply failed offset=#{offset}, NOT committing (retry): #{inspect(reason)}"
    )

    :retry
  end

  defp notify_test(envelope, result) do
    case Application.get_env(:message_service, :inbox_projection_test_pid) do
      pid when is_pid(pid) ->
        conversation_id = envelope |> Map.get("payload", %{}) |> Map.get("conversation_id")
        send(pid, {:inbox_projection_applied, conversation_id, result})

      _ ->
        :ok
    end
  end
end
