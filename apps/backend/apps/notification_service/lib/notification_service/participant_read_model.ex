defmodule NotificationService.ParticipantReadModel do
  @moduledoc """
  Idempotent, out-of-order-tolerant local participant read-model from
  `conversation.participant_added.v1` / `conversation.participant_removed.v1`.

  TWO independent correctness mechanisms (do not conflate them):

    1. DEDUPE (same-event redelivery): `INSERT ... ON CONFLICT DO NOTHING` into
       `notification_processed_events` keyed `(consumer, event_id)` with a DISTINCT consumer
       name (`#{inspect("notification-participants")}`) so it dedupes independently of the
       message→notification consumer. Affected count `1` ⇒ NEW, `0` ⇒ DUPLICATE.
    2. LAST-WRITER-WINS (different events, out-of-order): we do NOT lean on Kafka ordering
       (conversation-service emits each event in its own Task → produce order ≠ logical
       order). The upsert applies a state change ONLY when the incoming `occurred_at >=` the
       stored `last_event_at`. Soft state (`active` boolean), NEVER hard-deleted: a late add
       after a remove is not lost, and a remove arriving before its add just creates an
       inactive row.

  Both run in ONE `Repo.transaction`. Returns
  `{:ok, :applied} | {:ok, :duplicate} | {:error, term}`.
  """

  import Ecto.Query

  alias NotificationService.Repo
  alias NotificationService.Schemas.ConversationParticipantReadModel
  alias NotificationService.Schemas.ProcessedEvent

  @consumer "notification-participants"

  @doc "Dedupe-ledger scope name for the read-model consumer (distinct from the message consumer)."
  def consumer_name, do: @consumer

  @spec apply_participant_added(map()) :: {:ok, :applied} | {:ok, :duplicate} | {:error, term()}
  def apply_participant_added(envelope) when is_map(envelope) do
    apply_change(envelope, true)
  end

  @spec apply_participant_removed(map()) :: {:ok, :applied} | {:ok, :duplicate} | {:error, term()}
  def apply_participant_removed(envelope) when is_map(envelope) do
    apply_change(envelope, false)
  end

  defp apply_change(envelope, active) do
    with {:ok, event_id} <- fetch_uuid(envelope, "event_id"),
         payload = Map.get(envelope, "payload", %{}),
         true <- is_map(payload),
         {:ok, conversation_id} <- fetch_uuid(payload, "conversation_id"),
         {:ok, user_id} <- fetch_uuid(payload, "user_id") do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      occurred_at = parse_timestamp(Map.get(envelope, "occurred_at"), now)
      role = if active, do: blank_to_nil(Map.get(payload, "role")), else: nil

      Repo.transaction(fn ->
        {dedupe_count, _} =
          Repo.insert_all(
            ProcessedEvent,
            [%{consumer: @consumer, event_id: event_id, inserted_at: now}],
            on_conflict: :nothing
          )

        if dedupe_count == 1 do
          upsert(conversation_id, user_id, active, role, occurred_at, now)
          :applied
        else
          :duplicate
        end
      end)
    else
      _ -> {:error, :invalid_event}
    end
  rescue
    error -> {:error, error}
  end

  # Last-writer-wins: the ON CONFLICT update is applied ONLY when the incoming event is at
  # least as new as the stored one (EXCLUDED.last_event_at >= existing.last_event_at). An
  # older (reordered) event inserts nothing new and leaves the row's state intact.
  defp upsert(conversation_id, user_id, active, role, occurred_at, now) do
    Repo.insert_all(
      ConversationParticipantReadModel,
      [
        %{
          conversation_id: conversation_id,
          user_id: user_id,
          active: active,
          role: role,
          last_event_at: occurred_at,
          updated_at: now
        }
      ],
      on_conflict:
        from(r in ConversationParticipantReadModel,
          where: fragment("EXCLUDED.last_event_at >= ?", r.last_event_at),
          update: [
            set: [
              active: fragment("EXCLUDED.active"),
              role: fragment("EXCLUDED.role"),
              last_event_at: fragment("EXCLUDED.last_event_at"),
              updated_at: fragment("EXCLUDED.updated_at")
            ]
          ]
        ),
      conflict_target: [:conversation_id, :user_id]
    )
  end

  # A non-UUID id is a STRUCTURALLY invalid (poison) event → {:error, :invalid_event} (the
  # consumer skips+commits) rather than a transient failure that would retry forever.
  defp fetch_uuid(map, key) do
    with value when is_binary(value) and value != "" <- Map.get(map, key),
         {:ok, uuid} <- Ecto.UUID.cast(value) do
      {:ok, uuid}
    else
      _ -> :error
    end
  end

  defp blank_to_nil(value) when is_binary(value) and value != "", do: value
  defp blank_to_nil(_), do: nil

  defp parse_timestamp(value, fallback) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      # Force microsecond precision: an ISO string without a fractional part parses to
      # second precision ({_, 0}), which Ecto's :utc_datetime_usec rejects.
      {:ok, datetime, _offset} -> %{datetime | microsecond: {elem(datetime.microsecond, 0), 6}}
      _ -> fallback
    end
  end

  defp parse_timestamp(_value, fallback), do: fallback
end
