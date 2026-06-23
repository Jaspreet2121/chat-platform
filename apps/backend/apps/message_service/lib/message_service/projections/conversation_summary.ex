defmodule MessageService.Projections.ConversationSummary do
  @moduledoc """
  Idempotent per-conversation message-summary projection from `message.created.v1`.

  `apply_message_created/1` is the reusable idempotency pattern (the blueprint for
  notification-service): in ONE `Repo.transaction`,
    1. `INSERT ... ON CONFLICT DO NOTHING` into `processed_events` keyed by
       `(consumer, event_id)`; if the affected count is 1 the event is NEW, if 0 it
       is a DUPLICATE (already applied);
    2. only when NEW, apply the summary upsert (atomic increment + last-message set).
  Because both happen in one transaction, a crash between them rolls both back, so an
  at-least-once redelivery re-runs atomically and the projection is applied exactly once.

  Returns `{:ok, :applied} | {:ok, :duplicate} | {:error, term}`. Callable directly by
  tests (deterministic, no broker) and by the consumer callback.
  """

  alias MessageService.Repo
  alias MessageService.Schemas.ConversationMessageSummary
  alias MessageService.Schemas.ProcessedEvent

  @consumer "conversation-summary"

  @doc "Dedupe-ledger scope name for this projection."
  def consumer_name, do: @consumer

  @spec apply_message_created(map()) :: {:ok, :applied} | {:ok, :duplicate} | {:error, term()}
  def apply_message_created(envelope) when is_map(envelope) do
    with {:ok, event_id} <- fetch_uuid(envelope, "event_id"),
         payload = Map.get(envelope, "payload", %{}),
         true <- is_map(payload),
         {:ok, conversation_id} <- fetch_uuid(payload, "conversation_id") do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      message_id = blank_to_nil(Map.get(payload, "message_id"))
      last_message_at = parse_timestamp(Map.get(payload, "created_at"), now)

      Repo.transaction(fn ->
        {dedupe_count, _} =
          Repo.insert_all(
            ProcessedEvent,
            [%{consumer: @consumer, event_id: event_id, inserted_at: now}],
            on_conflict: :nothing
          )

        if dedupe_count == 1 do
          upsert_summary(conversation_id, message_id, last_message_at, now)
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

  defp upsert_summary(conversation_id, message_id, last_message_at, now) do
    Repo.insert_all(
      ConversationMessageSummary,
      [
        %{
          conversation_id: conversation_id,
          message_count: 1,
          last_message_id: message_id,
          last_message_at: last_message_at,
          updated_at: now
        }
      ],
      on_conflict: [
        inc: [message_count: 1],
        set: [last_message_id: message_id, last_message_at: last_message_at, updated_at: now]
      ],
      conflict_target: :conversation_id
    )
  end

  # Both event_id and conversation_id are binary_id columns. A non-UUID value is a
  # STRUCTURALLY invalid (poison) event, not a transient failure: returning :error here
  # surfaces {:error, :invalid_event}, which the consumer skips+commits rather than
  # retrying forever. (Without this, a malformed id raises Ecto.ChangeError inside the
  # transaction, which the consumer would treat as transient and redeliver indefinitely.)
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
