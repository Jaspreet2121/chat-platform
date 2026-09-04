defmodule MessageService.Events.SearchIndexConsumer do
  @moduledoc """
  Stateful, idempotent `brod_group_subscriber_v2` consumer for `message.events.v1`, maintaining the
  search-only copy of message text via `MessageService.Projections.SearchIndex`.

  Started ONLY under `KAFKA_SEARCH_CONSUMER_ENABLED`, in a DISTINCT group
  (`message-service-search-index`) so its offsets and failures are independent of the other
  consumers on the same topic. Copied from `InboxProjectionConsumer` rather than extended, per the
  standing rule.

  Commit ordering (at-least-once): DB work first, offset committed only on success. Transient →
  `{:ok, state}` (redeliver); structurally invalid or poison → log + commit so one event cannot
  wedge the partition.

  ## `undefined_table` is RETRY here, NOT poison — a deliberate divergence from the inbox consumer

  The inbox consumer classifies every `Postgrex.Error` as poison (drop + commit). Applied here, a
  deploy that beats the 094 migration would turn EVERY event into a permanent drop — messages that
  would silently never be searchable, the exact loss shape the inbox consumer's classification once
  caused for a different reason. A missing table is not a property of the event; it is an
  operational precondition, fixed by applying the migration. So `42P01 undefined_table` retries:
  code-before-migration stalls this consumer loudly (error log per attempt, offsets not advancing)
  instead of losing data, and applying 094 unwedges it with nothing lost. Migration-first is still
  the deploy order; this changes what a violation costs.
  """

  @behaviour :brod_group_subscriber_v2

  require Logger
  require Record

  alias MessageService.Projections.SearchIndex

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
        SharedInfra.Correlation.put(envelope["correlation_id"])
        result = SearchIndex.apply_event(envelope)
        notify_test(envelope, result)
        commit_decision(result, offset)

      {:error, reason} ->
        Logger.warning(
          "search-index: JSON decode failed offset=#{offset}, skipping: #{inspect(reason)}"
        )

        :commit
    end
  end

  @doc false
  # Public so the classification is assertable without a broker (the 0c13a38 precedent).
  def commit_decision({:ok, _outcome}, _offset), do: :commit

  def commit_decision({:error, :invalid_event}, offset) do
    Logger.warning("search-index: invalid event offset=#{offset}, skipping (commit)")
    :commit
  end

  # The missing-table precondition: retry, never drop. See the moduledoc.
  def commit_decision({:error, %Postgrex.Error{postgres: %{code: :undefined_table}}}, offset) do
    Logger.error(
      "search-index: message_search table MISSING offset=#{offset} — the 094 migration has not " <>
        "been applied. RETRYING (not dropping): apply the migration to unwedge this consumer."
    )

    :retry
  end

  # POISON: deterministic-in-the-event errors that cannot succeed on retry. Same classification as
  # the inbox consumer, minus the undefined_table carve-out above.
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
      "search-index: POISON event offset=#{offset} (#{inspect(struct)}) — " <>
        "committing to skip. This is a code defect; the index has DROPPED this event."
    )

    :commit
  end

  def commit_decision({:error, reason}, offset) do
    Logger.warning(
      "search-index: apply failed offset=#{offset}, NOT committing (retry): #{inspect(reason)}"
    )

    :retry
  end

  defp notify_test(envelope, result) do
    case Application.get_env(:message_service, :search_index_test_pid) do
      pid when is_pid(pid) ->
        message_id = envelope |> Map.get("payload", %{}) |> Map.get("message_id")
        send(pid, {:search_index_applied, message_id, result})

      _ ->
        :ok
    end
  end
end
