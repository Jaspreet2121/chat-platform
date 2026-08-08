defmodule MessageService.Projections.SearchIndex do
  @moduledoc """
  Maintains `message_search` — the SEARCH-ONLY COPY of message text (DECISION_LOG [2026-08-08]) —
  from `message.events.v1`, for the world where messages live in Scylla and Postgres `messages` is
  frozen.

  COPIED from `MessageService.Projections.InboxFromTopic`, not extended, for that module's own
  recorded reason: sharing a module couples two projections to one consumer offset and one failure
  domain. Own `@consumer` scope in the shared `processed_events` ledger; own group id; own flag.

  ## What this is, honestly

  A second copy of message content, in Postgres, with a retention of its own. The decision to keep
  bodies OFF the Kafka topic still stands (a topic copy has a retention deletion cannot reach); this
  table is the copy deletion CAN reach, and the plumbing is the point:

    * `message.created.v1` → read the body back from the STORE (thin payload carries none) → upsert.
      A message deleted before its create is consumed reads back absent → ledger + skip, so a
      tombstoned message is never indexed at all.
    * `message.deleted.v1` → DELETE the row by primary key. Create and delete share a partition key
      (`conversation_id`), so a delete can never overtake its create.
    * The row is an OVERWRITE upsert: the read-back at consume time always carries the CURRENT body,
      so replays and the synchronous edit overwrite (`refresh_text/3`, called from the Scylla
      adapter's edit path — edits publish no event) converge on the newest text in any order.

  What deletion latency means for a user: the index row lingers for consumer lag; the CONTENT never
  renders during that lag, because search results are hydrated by point-reading the authoritative
  store, which returns the tombstone (see `ScyllaAdapter.search_messages/1`).

  ## No adapter self-gate, deliberately — unlike InboxFromTopic

  InboxFromTopic self-gates under the Postgres adapter because that adapter maintains the same
  columns in-transaction and two writers double-count. Nothing else writes `message_search` rows
  with different semantics: the consumer, the edit overwrite and the backfill all write the same
  content-derived value, idempotently. Running under the Postgres adapter is harmless (the table is
  simply not read there) and keeps the index warm across a rollback.

  ## Idempotency and the backfill

  Ledger insert + projection write in ONE transaction, the ConversationSummary contract. The one-off
  backfill (`MessageService.SearchBackfill`) may run while this consumer is live: it inserts with
  `ON CONFLICT DO NOTHING`, so it can never overwrite a fresher consumer- or edit-written row with
  its older Scylla read. The residual window — a message deleted between the backfill's read and its
  insert leaves a row no future event deletes — is bounded by hydration: the row cannot render.
  """

  alias MessageService.MessageStore
  alias MessageService.Repo
  alias MessageService.Schemas.ProcessedEvent

  @consumer "search-index"

  @doc "Dedupe-ledger scope name for this projection."
  def consumer_name, do: @consumer

  @type result ::
          {:ok, :applied | :duplicate | :skipped_absent | :ignored}
          | {:error, term()}

  @doc "Route an envelope by its `event_type`. Unknown types are ignored, not errors."
  @spec apply_event(map()) :: result()
  def apply_event(%{} = envelope) do
    case Map.get(envelope, "event_type") do
      "message.created.v1" -> apply_message_created(envelope)
      "message.deleted.v1" -> apply_message_deleted(envelope)
      _ -> {:ok, :ignored}
    end
  end

  def apply_event(_), do: {:error, :invalid_event}

  @spec apply_message_created(map()) :: result()
  def apply_message_created(%{} = envelope) do
    with {:ok, event_id} <- fetch(envelope, "event_id"),
         payload when is_map(payload) <- Map.get(envelope, "payload", %{}),
         {:ok, conversation_id} <- fetch(payload, "conversation_id"),
         {:ok, message_id} <- fetch(payload, "message_id") do
      # Store read OUTSIDE the transaction — the InboxFromTopic rule, same reason: a Scylla point
      # read inside Repo.transaction holds a Postgres connection across another store's latency.
      case read_back(conversation_id, message_id) do
        {:ok, message} ->
          transact(event_id, fn -> upsert(message) end)

        :absent ->
          # Deleted (or never found) before this event was consumed: index NOTHING, ledger it so
          # redelivery does not retry. This is deletion-propagation's front door.
          transact(event_id, fn -> :ok end, :skipped_absent)
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_event}
    end
  rescue
    error -> {:error, error}
  end

  @spec apply_message_deleted(map()) :: result()
  def apply_message_deleted(%{} = envelope) do
    with {:ok, event_id} <- fetch(envelope, "event_id"),
         payload when is_map(payload) <- Map.get(envelope, "payload", %{}),
         {:ok, _conversation_id} <- fetch(payload, "conversation_id"),
         {:ok, message_id} <- fetch(payload, "message_id") do
      transact(event_id, fn ->
        Repo.query!("DELETE FROM message_search WHERE message_id = $1::text::uuid", [message_id])
        :ok
      end)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_event}
    end
  rescue
    error -> {:error, error}
  end

  @doc """
  Synchronous best-effort text refresh for the EDIT path — edits publish no event, so without this
  the index would keep matching the pre-edit text forever (the user who edited a phone number out
  would still be findable by it). Called from the Scylla adapter after a successful body edit.

  A no-op when no row exists yet: the create consumer's read-back will index the post-edit body
  anyway, which is also why an edit racing ahead of its create needs no special handling.
  """
  def refresh_text(message_id, body, edited_at) when is_binary(body) do
    Repo.query!(
      "UPDATE message_search SET search_text = $2 WHERE message_id = $1::text::uuid",
      [message_id, body]
    )

    _ = edited_at
    :ok
  end

  def refresh_text(_message_id, _body, _edited_at), do: :ok

  @doc """
  Upsert one message into the index from a store-shaped map (atom keys, `%DateTime{}` created_at).
  OVERWRITE semantics — consumer and edit path always carry the current body. The backfill
  deliberately does NOT use this (it must never overwrite; see `MessageService.SearchBackfill`).
  """
  def upsert(%{} = message) do
    Repo.query!(
      "INSERT INTO message_search (message_id, conversation_id, sender_user_id, created_at, search_text) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, $4, $5) " <>
        "ON CONFLICT (message_id) DO UPDATE SET search_text = EXCLUDED.search_text",
      [
        message.message_id,
        message.conversation_id,
        message.sender_user_id,
        message.created_at,
        message.body || ""
      ]
    )

    :ok
  end

  # --- shared plumbing (the InboxFromTopic shapes) -------------------------------------------------

  defp transact(event_id, fun, applied_tag \\ :applied) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.transaction(fn ->
      {dedupe_count, _} =
        Repo.insert_all(
          ProcessedEvent,
          [%{consumer: @consumer, event_id: event_id, inserted_at: now}],
          on_conflict: :nothing
        )

      if dedupe_count == 1 do
        fun.()
        applied_tag
      else
        :duplicate
      end
    end)
  end

  defp read_back(conversation_id, message_id) do
    case MessageStore.get_message(%{
           "conversation_id" => conversation_id,
           "message_id" => message_id
         }) do
      {:ok, message} ->
        if deleted?(message), do: :absent, else: {:ok, normalise(message)}

      _ ->
        :absent
    end
  end

  defp deleted?(message) do
    get(message, :status) == "deleted" or not is_nil(get(message, :deleted_at))
  end

  defp normalise(message) do
    %{
      conversation_id: get(message, :conversation_id),
      message_id: get(message, :message_id),
      sender_user_id: get(message, :sender_user_id),
      body: get(message, :body),
      created_at: get(message, :created_at)
    }
  end

  defp fetch(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_event}
    end
  end

  defp get(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end
