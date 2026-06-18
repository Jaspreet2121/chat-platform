defmodule NotificationService.Notifications do
  @moduledoc """
  Idempotent notification creation from `message.created.v1`.

  `apply_message_created/1` is the dedupe core copied from
  `MessageService.Projections.ConversationSummary` (intentionally NOT extracted into a
  shared base yet — that is a deferred refactor). In ONE `Repo.transaction`:
    1. `INSERT ... ON CONFLICT DO NOTHING` into `notification_processed_events` keyed
       `(consumer, event_id)`; affected count `1` ⇒ NEW, `0` ⇒ DUPLICATE;
    2. only when NEW, insert ONE notification row.
  Both happen in one transaction, so an at-least-once redelivery re-runs atomically and
  the notification is created exactly once.

  Returns `{:ok, :applied} | {:ok, :duplicate} | {:error, term}`. The first slice does NOT
  resolve recipients (one record per event, not per participant).
  """

  alias NotificationService.Repo
  alias NotificationService.Schemas.Notification
  alias NotificationService.Schemas.ProcessedEvent

  @consumer "notification"
  @type_message_created "message_created"

  @doc "Dedupe-ledger scope name for this consumer."
  def consumer_name, do: @consumer

  @spec apply_message_created(map()) :: {:ok, :applied} | {:ok, :duplicate} | {:error, term()}
  def apply_message_created(envelope) when is_map(envelope) do
    with {:ok, event_id} <- fetch_uuid(envelope, "event_id"),
         payload = Map.get(envelope, "payload", %{}),
         true <- is_map(payload),
         {:ok, conversation_id} <- fetch_uuid(payload, "conversation_id"),
         {:ok, message_id} <- fetch_uuid(payload, "message_id"),
         {:ok, sender_user_id} <- fetch_uuid(payload, "sender_user_id") do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      created_at = parse_timestamp(Map.get(payload, "created_at"), now)

      Repo.transaction(fn ->
        {dedupe_count, _} =
          Repo.insert_all(
            ProcessedEvent,
            [%{consumer: @consumer, event_id: event_id, inserted_at: now}],
            on_conflict: :nothing
          )

        if dedupe_count == 1 do
          insert_notification(%{
            event_id: event_id,
            conversation_id: conversation_id,
            message_id: message_id,
            sender_user_id: sender_user_id,
            created_at: created_at,
            now: now
          })

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

  defp insert_notification(attrs) do
    Repo.insert_all(Notification, [
      %{
        id: Ecto.UUID.generate(),
        type: @type_message_created,
        source_event_id: attrs.event_id,
        conversation_id: attrs.conversation_id,
        message_id: attrs.message_id,
        sender_user_id: attrs.sender_user_id,
        read: false,
        created_at: attrs.created_at,
        inserted_at: attrs.now
      }
    ])
  end

  # Both event_id and the payload ids are binary_id columns. A non-UUID value is a
  # STRUCTURALLY invalid (poison) event, not a transient failure: returning :error here
  # surfaces {:error, :invalid_event}, which the consumer skips+commits rather than
  # retrying forever.
  defp fetch_uuid(map, key) do
    with value when is_binary(value) and value != "" <- Map.get(map, key),
         {:ok, uuid} <- Ecto.UUID.cast(value) do
      {:ok, uuid}
    else
      _ -> :error
    end
  end

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
