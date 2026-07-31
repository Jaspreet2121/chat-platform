defmodule NotificationService.Notifications do
  @moduledoc """
  Recipient FAN-OUT from `message.created.v1`: one notification per active conversation
  participant (resolved from the local `conversation_participants_readmodel`), EXCLUDING the
  sender. In ONE `Repo.transaction`:
    1. `INSERT ... ON CONFLICT DO NOTHING` into `notification_processed_events` keyed
       `(consumer, event_id)` — the COARSE event-level gate (count `1` ⇒ NEW, `0` ⇒ DUPLICATE);
    2. only when NEW, read the active recipient set and `insert_all` one notification per
       recipient with `on_conflict: :nothing` on the UNIQUE `(source_event_id, recipient_user_id)`
       index — the durable per-recipient guard (safe under redelivery/retry and a participant
       set that grew between deliveries).

  If the read-model has no active participants for the conversation yet (cold-start / the
  participant events haven't been consumed), fan-out notifies NOBODY (0 rows) and is NOT
  retried — an accepted eventual-consistency limitation.

  Returns `{:ok, :applied} | {:ok, :duplicate} | {:error, term}`.
  """

  import Ecto.Query

  alias NotificationService.Repo
  alias NotificationService.Schemas.ConversationParticipantReadModel
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

      attrs = %{
        event_id: event_id,
        conversation_id: conversation_id,
        message_id: message_id,
        sender_user_id: sender_user_id,
        created_at: created_at,
        now: now
      }

      result =
        Repo.transaction(fn ->
          {dedupe_count, _} =
            Repo.insert_all(
              ProcessedEvent,
              [%{consumer: @consumer, event_id: event_id, inserted_at: now}],
              on_conflict: :nothing
            )

          if dedupe_count == 1 do
            recipients = active_recipients(conversation_id, sender_user_id)
            fan_out(attrs, recipients)
            {:applied, recipients}
          else
            :duplicate
          end
        end)

      # Web-push sender leg (Phase 1) — AFTER the commit, never inside the transaction, and only for
      # the FIRST application of the event (dedupe means retries/redeliveries don't re-push).
      case result do
        {:ok, {:applied, recipients}} ->
          NotificationService.PushSender.push_message_created(attrs, recipients)

          # Android leg (Phase 2), fired side by side with web-push: a recipient may have browsers,
          # handsets, or both. Each leg owns its own device table and its own suppression, so this
          # changes nothing about fan-out or dedupe.
          NotificationService.FcmSender.push_message_created(attrs, recipients)
          {:ok, :applied}

        other ->
          other
      end
    else
      _ -> {:error, :invalid_event}
    end
  rescue
    error -> {:error, error}
  end

  # One notification per active participant, EXCLUDING the sender. Empty set (cold-start) →
  # no rows, no error. on_conflict :nothing on the unique (source_event_id, recipient_user_id)
  # index makes this idempotent per recipient.
  defp fan_out(attrs, recipients) do
    rows =
      Enum.map(recipients, fn recipient_user_id ->
        %{
          id: Ecto.UUID.generate(),
          type: @type_message_created,
          source_event_id: attrs.event_id,
          recipient_user_id: recipient_user_id,
          conversation_id: attrs.conversation_id,
          message_id: attrs.message_id,
          sender_user_id: attrs.sender_user_id,
          read: false,
          created_at: attrs.created_at,
          inserted_at: attrs.now
        }
      end)

    case rows do
      [] ->
        {0, nil}

      _ ->
        Repo.insert_all(Notification, rows,
          on_conflict: :nothing,
          conflict_target: [:source_event_id, :recipient_user_id]
        )
    end
  end

  defp active_recipients(conversation_id, sender_user_id) do
    Repo.all(
      from(r in ConversationParticipantReadModel,
        where:
          r.conversation_id == ^conversation_id and r.active == true and
            r.user_id != ^sender_user_id,
        select: r.user_id
      )
    )
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
