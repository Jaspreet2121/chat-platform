defmodule NotificationService.Events.ConversationParticipantsConsumer do
  @moduledoc """
  Stateful, idempotent `brod_group_subscriber_v2` consumer for `conversation.events.v1`,
  maintaining the local participant read-model
  (`NotificationService.ParticipantReadModel`).

  Runs in a DISTINCT group (`notification-service-conversation-participants`) so its
  offsets/processing are independent of the message→notification consumer (which is on a
  different topic anyway). Dispatches on `event_type`:
    * `conversation.participant_added.v1`   → `apply_participant_added/1`
    * `conversation.participant_removed.v1` → `apply_participant_removed/1`
    * any other event_type on the topic     → ignored (skip + commit)

  Commit ordering (at-least-once): DB work runs FIRST; commit only on success
  (applied/duplicate or an ignored event). Transient DB error → no commit (redeliver).
  Structurally invalid / undecodable (poison) event → log + commit (skip; never wedge).
  """

  @behaviour :brod_group_subscriber_v2

  require Logger
  require Record

  alias NotificationService.ParticipantReadModel

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
        result = apply_event(envelope)
        notify_test(envelope, result)
        commit_decision(result, offset)

      {:error, reason} ->
        # Poison/undecodable → log + commit (skip; never wedge the partition).
        Logger.warning(
          "notification-participants: JSON decode failed offset=#{offset}, skipping: #{inspect(reason)}"
        )

        :commit
    end
  end

  defp apply_event(%{"event_type" => "conversation.participant_added.v1"} = envelope) do
    ParticipantReadModel.apply_participant_added(envelope)
  end

  defp apply_event(%{"event_type" => "conversation.participant_removed.v1"} = envelope) do
    ParticipantReadModel.apply_participant_removed(envelope)
  end

  # Any other event_type on conversation.events.v1 is not relevant to the read-model.
  defp apply_event(_envelope), do: {:ok, :ignored}

  defp commit_decision({:ok, :applied}, _offset), do: :commit
  defp commit_decision({:ok, :duplicate}, _offset), do: :commit
  defp commit_decision({:ok, :ignored}, _offset), do: :commit

  defp commit_decision({:error, :invalid_event}, offset) do
    Logger.warning("notification-participants: invalid event offset=#{offset}, skipping (commit)")
    :commit
  end

  defp commit_decision({:error, reason}, offset) do
    Logger.warning(
      "notification-participants: apply failed offset=#{offset}, NOT committing (retry): #{inspect(reason)}"
    )

    :retry
  end

  defp notify_test(envelope, result) do
    case Application.get_env(:notification_service, :participant_readmodel_test_pid) do
      pid when is_pid(pid) ->
        send(pid, {:participant_readmodel_applied, Map.get(envelope, "event_id"), result})

      _ ->
        :ok
    end
  end
end
