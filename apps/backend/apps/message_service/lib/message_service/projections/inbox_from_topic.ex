defmodule MessageService.Projections.InboxFromTopic do
  @moduledoc """
  Maintains the DENORMALISED INBOX ROW (086) from `message.events.v1`, for the world where messages
  live in Scylla and the same-transaction write in `MessageStore.PostgresAdapter` no longer happens.

  COPIED from `MessageService.Projections.ConversationSummary`, not extended: that projection owns
  `conversation_message_summaries`, a different entity. Sharing a module would couple two projections
  to one consumer offset and one failure domain. notification-service made the same copy for the same
  reason. The shared `processed_events` ledger is keyed `(consumer, event_id)`, so a new `@consumer`
  scope needs no migration.

  ## Why the body is read back rather than carried on the topic

  The payload is deliberately thin (no `body`). Putting message bodies on a Kafka topic mints a second
  copy with its own retention that delete-for-everyone cannot reach — and this product's spine is that
  a user controls their own content. The body is read back from the store instead, so deletion is
  genuinely effective: a deleted message reads back ABSENT and this projection skips it.

  The read-back is cheap at scale for the reason the key makes possible: `message.events.v1` is keyed
  by `conversation_id`, so per-conversation order holds and a BACKLOG COLLAPSES — only the newest
  event per conversation actually changes the preview.

  ## THE READ-BACK IS OUTSIDE THE TRANSACTION, deliberately

  A Scylla point read inside `Repo.transaction` would hold a Postgres connection open across a network
  call to a different store — a connection-pool stall driven by another system's latency. Every store
  read here happens BEFORE the transaction opens and its result is passed in.

  ## Idempotency

  The ledger insert and the projection write share ONE transaction (the ConversationSummary contract):
  a crash between them rolls both back, so at-least-once redelivery re-runs atomically and applies
  exactly once. This is what makes this consumer the SINGLE idempotent writer of the increment, which
  the recount design depends on.

  ## Replaying from offset zero — what the ledger does and does not cover

  The consumer subscribes with `begin_offset: :earliest`, so a first enable replays the whole
  retained topic rather than silently skipping it. Three different things happen to a replayed event:

    * **Already in the ledger** — `{:ok, :duplicate}`, nothing written. Safe at any age.
    * **The preview** — safe at any age. `InboxProjection.record_message/1`'s UPDATE is guarded by
      `last_message_at <= $3`, so an older replayed event CANNOT overwrite a newer preview.
    * **`unread_count` for events OLDER THAN THE LEDGER'S FIRST ROW — NOT safe.** Those events are
      absent from the ledger, so they are treated as new and the counter is incremented for messages
      the user may have read long ago. The increment is unconditional by design (a genuinely new
      message is inside every window), and a replay violates that assumption.

  What bounds it: Kafka topic retention caps how far back a replay reaches, and the existing
  read-time recount repairs the counter when the `oldest_unread_at` watermark fails its freshness
  test. What does NOT bound it: anything in this module.

  ONE SHARP CONSEQUENCE, because it is easy to miss. While `PostgresAdapter` is selected every apply
  self-gates and returns before `transact/3`, so it writes **no ledger row**. Those events are
  therefore NOT marked as seen — at the cutover the consumer replays them and applies them for real.
  That is intended (the recent backlog should land), but it means the inflation above is proportional
  to retained history at the moment of cutover, not to the time since the flag was enabled.

  ## The backlog-collapse claim, which the implementation does NOT make good on

  The design that chose this shape (thin payload + read-back, over putting bodies on the topic)
  argued the read-back cost away by saying a backlog collapses: because the topic is keyed by
  `conversation_id`, only the newest event per conversation changes the preview, so N events should
  cost one read-back per CONVERSATION.

  `apply_message_created/1` calls `read_back/2` once per EVENT, unconditionally. There is no collapse
  logic here. Measured end-to-end: 3 creates produced 3 `get_message` calls.

  So the claim is UNEARNED and should not be repeated. The decision to keep bodies off the topic
  stands on its own — deletion must be genuinely effective, and a Kafka copy has a retention this
  system cannot reach — but it does not currently stand on the cost argument. Batching per
  conversation is a follow-up for when volume justifies it; it is deliberately not built.

  ## Coexistence with `MessageService.InboxProjection` — the data-corruption hazard

  `InboxProjection` writes the SAME columns, from inside `MessageStore.PostgresAdapter` (its four call
  sites are all in that adapter). Under `MESSAGE_STORE_ADAPTER=postgres` it runs; under `scylla` it
  does not. So the two writers are mutually exclusive BY ADAPTER — but this consumer is started by its
  own flag, independent of the adapter, and `postgres + consumer ON` would DOUBLE-INCREMENT every
  unread counter.

  A flag-ordering convention is not enough for something that corrupts live counters, so this module
  SELF-GATES: if the selected store adapter is the Postgres one, every apply returns
  `{:ok, :skipped_postgres_adapter}` and writes nothing. Enabling the flag early is therefore inert
  rather than destructive, and the cutover can flip adapter and flag in either order.
  """

  alias MessageService.InboxProjection
  alias MessageService.MessageStore
  alias MessageService.Repo
  alias MessageService.VisibilityWindow
  alias MessageService.Schemas.ProcessedEvent

  @consumer "inbox-from-topic"

  @doc "Dedupe-ledger scope name for this projection."
  def consumer_name, do: @consumer

  @type result ::
          {:ok, :applied | :duplicate | :skipped_postgres_adapter | :skipped_absent | :ignored}
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

  @doc """
  A new message: increment unread for every active participant except the sender, and refresh the
  conversation preview.

  READ-BACK NOT FOUND IS A VALID OUTCOME, NOT AN ERROR TO RETRY. It means the message was created and
  then deleted before this event was processed. Defined behaviour: **ledger the event and SETTLE the
  message** — insert `inbox_read_marks` rows for every would-have-been recipient, in the same
  transaction as the ledger row. No increment happens (the user can never open the message), and the
  settle-marks are what stop the LATER delete event (always later: same partition key) from
  decrementing recipients who were never incremented. Without them, a fast delete drifts every
  recipient by -1 — floored to invisibility for some, stealing a count from a DIFFERENT unread
  message for others. The preview keeps showing whatever it showed.
  """
  @spec apply_message_created(map()) :: result()
  def apply_message_created(%{} = envelope) do
    with :ok <- ensure_not_postgres_adapter(),
         {:ok, event_id} <- fetch(envelope, "event_id"),
         payload when is_map(payload) <- Map.get(envelope, "payload", %{}),
         {:ok, conversation_id} <- fetch(payload, "conversation_id"),
         {:ok, message_id} <- fetch(payload, "message_id") do
      # OUTSIDE the transaction. See the moduledoc.
      case read_back(conversation_id, message_id) do
        {:ok, stored} ->
          transact(event_id, fn -> InboxProjection.record_message(stored) end)

        :absent ->
          # Ledger + SETTLE (see the doc above): the marks are what make the coming delete event a
          # no-op for recipients this create never incremented.
          sender = Map.get(payload, "sender_user_id")

          transact(
            event_id,
            fn -> settle_all_recipients(conversation_id, message_id, sender) end,
            :skipped_absent
          )
      end
    else
      {:ok, :skipped_postgres_adapter} = skip -> skip
      {:error, _} = error -> error
      _ -> {:error, :invalid_event}
    end
  rescue
    error -> {:error, error}
  end

  @doc """
  A delete-for-everyone: if the deleted message WAS the preview, promote the next-newest live message
  from the STORE.

  This is the privacy-critical half. Without it a preview maintained from creates alone keeps showing
  the deleted message's text in the chat list forever — deleted content on screen, which is the class
  of failure this codebase has already fixed twice.

  It deliberately does NOT reuse `InboxProjection.record_delete/1`: that function's
  `refresh_preview_if_last` reads Postgres `messages` for the next-newest and CLEARS the preview when
  it finds none. With messages in Scylla it would find none every time and nil every preview — worse
  than doing nothing.

  UNREAD IS DECREMENTED HERE (since 2026-08-09; it was scoped out of the original slice), and the
  consumer is the right side of the read-path asymmetry: deletes HAVE an ordered event, a ledger and
  this handler, so a crash between the Scylla tombstone and the Postgres decrement redelivers and
  re-runs atomically — the synchronous read decrement had no event to lean on and accepted
  best-effort instead.

  Exactly-once, two layers: the LEDGER dedupes a redelivered event (the decrement runs inside
  `transact`), and PER-RECIPIENT CLAIMS in `inbox_read_marks` cover what the ledger cannot — a
  second, distinct delete event for the same message claims zero rows and decrements nobody. A
  mark's meaning is "this (message, recipient) counter is SETTLED, no further effect" (DECISION_LOG
  2026-08-09): the reader's mark blocks this decrement (their read already decremented), this
  decrement's mark blocks a later read claim, and the create-skip settle-marks block the
  delete-before-create drift. One CTE statement claims and decrements the claimed set — a 50-member
  group is one round trip, not 49.

  WHO: the increment's population (active, non-sender, unmarked) under the READ decrement's guards
  (participant window, GREATEST floor, watermark NULLed at zero). The window guard is required, not
  decorative: clear_history zeroes the counter AND sets cleared_before, so decrementing a cleared
  message would steal from newer ones. Its auto-delete half costs a stuck +1 for aged-out
  deleted-unread — the same accepted non-decay class as everywhere else.

  ACCEPTED RESIDUAL (interleaving row 8 of the design review): a delete whose CREATE event was lost
  (fire-and-forget publish failure) decrements a message that was never counted — floored at 0, or
  -1 drift if the recipient holds other unread. Unfixable without per-(message,recipient) increment
  evidence, which would mean a row for every message x recipient. The same exposure already exists
  on the read path for never-incremented messages.
  """
  @spec apply_message_deleted(map()) :: result()
  def apply_message_deleted(%{} = envelope) do
    with :ok <- ensure_not_postgres_adapter(),
         {:ok, event_id} <- fetch(envelope, "event_id"),
         payload when is_map(payload) <- Map.get(envelope, "payload", %{}),
         {:ok, conversation_id} <- fetch(payload, "conversation_id"),
         {:ok, message_id} <- fetch(payload, "message_id"),
         # Required: without the sender the decrement cannot exclude them. Every produced
         # message.deleted.v1 has carried sender_user_id since the event existed (f95d031).
         {:ok, sender_user_id} <- fetch(payload, "sender_user_id") do
      # Store read OUTSIDE the transaction, same rule as the created path. The tombstone point read
      # supplies created_at for the window guard — the thin payload does not carry it.
      created_at = tombstone_created_at(conversation_id, message_id)

      if preview?(conversation_id, message_id) do
        replacement = next_live_message(conversation_id, message_id)

        transact(event_id, fn ->
          write_preview(conversation_id, replacement)
          decrement_for_delete(conversation_id, message_id, sender_user_id, created_at)
        end)
      else
        transact(event_id, fn ->
          decrement_for_delete(conversation_id, message_id, sender_user_id, created_at)
        end)
      end
    else
      {:ok, :skipped_postgres_adapter} = skip -> skip
      {:error, _} = error -> error
      _ -> {:error, :invalid_event}
    end
  rescue
    error -> {:error, error}
  end

  # --- the shared idempotency contract -------------------------------------------------------------

  # Ledger insert + projection write in ONE transaction: a crash between them rolls both back, so
  # redelivery re-runs atomically. Verbatim shape from ConversationSummary.apply_message_created/1.
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

  # --- store reads (all OUTSIDE any transaction) ---------------------------------------------------

  # `:absent` covers both "deleted" and "never found" — the caller treats them identically, because
  # from the inbox's point of view a tombstoned message and a missing one are the same thing.
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

  # The newest live message that is not the one just deleted. `nil` means the conversation has no
  # live message left, and the preview is cleared.
  defp next_live_message(conversation_id, deleted_message_id) do
    case MessageStore.list_messages(%{"conversation_id" => conversation_id, "limit" => 20}) do
      {:ok, %{messages: messages}} when is_list(messages) ->
        messages
        |> Enum.reject(&(get(&1, :message_id) == deleted_message_id or deleted?(&1)))
        |> List.first()
        |> case do
          nil -> nil
          message -> normalise(message)
        end

      _ ->
        nil
    end
  end

  # --- Postgres writes -----------------------------------------------------------------------------

  defp preview?(conversation_id, message_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM conversations WHERE id = $1::text::uuid AND last_message_id = $2::text::uuid",
        [conversation_id, message_id]
      )

    rows != []
  end

  defp write_preview(conversation_id, nil) do
    Repo.query!(
      "UPDATE conversations SET last_message_id = NULL, last_message_at = NULL, " <>
        "last_message_body = NULL, last_message_type = NULL, " <>
        "last_message_content_type = NULL, last_message_sender_id = NULL " <>
        "WHERE id = $1::text::uuid",
      [conversation_id]
    )

    :ok
  end

  defp write_preview(_conversation_id, %{} = message) do
    # NOT `InboxProjection.record_message/1`, even though it writes these same columns: that function
    # ALSO increments unread, and this is a promotion of a message everyone was already counted for.
    # Reusing it would inflate every participant's unread on someone else's delete.
    #
    # Also note the missing `last_message_at <= $3` guard that record_message carries: that guard
    # exists to stop an out-of-order INSERT overwriting a newer preview. Here we are deliberately
    # moving the preview BACKWARDS to an older message, so the guard would reject the write.
    Repo.query!(
      "UPDATE conversations SET " <>
        "last_message_id = $2::text::uuid, last_message_at = $3, last_message_body = $4, " <>
        "last_message_type = $5, last_message_content_type = $6, last_message_sender_id = $7::text::uuid " <>
        "WHERE id = $1::text::uuid",
      [
        message.conversation_id,
        message.message_id,
        message.created_at,
        message.body,
        message.message_type,
        content_type(message),
        message.sender_user_id
      ]
    )

    :ok
  end

  # --- the unread decrement + settlement (delete-for-everyone) -------------------------------------

  # ONE statement, claim-then-decrement: insert a settle-mark for every qualifying recipient
  # (ON CONFLICT DO NOTHING — readers, prior deletes and create-skip settles all conflict) and
  # decrement EXACTLY the claimed set. Population mirrors the increment (active, non-sender);
  # guards mirror the read decrement (participant window, floor, watermark). A NULL created_at
  # (tombstone unreadable) makes the window predicates NULL -> false for participants WITH window
  # prefs — conservatively skipping them rather than guessing.
  defp decrement_for_delete(conversation_id, message_id, sender_user_id, created_at) do
    Repo.query!(
      "WITH claimed AS (" <>
        "INSERT INTO inbox_read_marks (conversation_id, message_id, user_id, message_created_at) " <>
        "SELECT cp.conversation_id, $2::text::uuid, cp.user_id, $4 " <>
        "FROM conversation_participants cp " <>
        "WHERE cp.conversation_id = $1::text::uuid AND cp.left_at IS NULL " <>
        "AND cp.user_id <> $3::text::uuid " <>
        "AND " <>
        VisibilityWindow.participant_window_sql("cp", "$4") <>
        " " <>
        "ON CONFLICT DO NOTHING RETURNING user_id) " <>
        "UPDATE conversation_participants cp SET " <>
        "unread_count = GREATEST(cp.unread_count - 1, 0), " <>
        "oldest_unread_at = CASE WHEN GREATEST(cp.unread_count - 1, 0) = 0 THEN NULL " <>
        "ELSE cp.oldest_unread_at END " <>
        "FROM claimed WHERE cp.conversation_id = $1::text::uuid AND cp.user_id = claimed.user_id",
      [conversation_id, message_id, sender_user_id, created_at]
    )

    :ok
  end

  # The create-skip settlement: the message was deleted before its create was consumed, so nobody
  # was incremented — mark every would-have-been recipient as settled so the coming delete event
  # claims nothing. Sender excluded when the payload carries them (their mark would never be
  # consulted anyway: the read path bails on own-sender, the delete claim excludes them).
  defp settle_all_recipients(conversation_id, message_id, sender_user_id) do
    sender_clause =
      if is_binary(sender_user_id) and sender_user_id != "",
        do: "AND cp.user_id <> $3::text::uuid ",
        else: ""

    params =
      if sender_clause == "",
        do: [conversation_id, message_id],
        else: [conversation_id, message_id, sender_user_id]

    Repo.query!(
      "INSERT INTO inbox_read_marks (conversation_id, message_id, user_id) " <>
        "SELECT cp.conversation_id, $2::text::uuid, cp.user_id " <>
        "FROM conversation_participants cp " <>
        "WHERE cp.conversation_id = $1::text::uuid AND cp.left_at IS NULL " <>
        sender_clause <>
        "ON CONFLICT DO NOTHING",
      params
    )

    :ok
  end

  # The tombstone still carries created_at (soft delete); :absent covers a hard-missing row.
  defp tombstone_created_at(conversation_id, message_id) do
    case MessageStore.get_message(%{
           "conversation_id" => conversation_id,
           "message_id" => message_id
         }) do
      {:ok, message} -> get(message, :created_at)
      _ -> nil
    end
  end

  # --- the adapter interlock -----------------------------------------------------------------------

  defp ensure_not_postgres_adapter do
    if Application.get_env(:message_service, :message_store_adapter) ==
         MessageStore.PostgresAdapter do
      {:ok, :skipped_postgres_adapter}
    else
      :ok
    end
  end

  # --- plumbing ------------------------------------------------------------------------------------

  defp fetch(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_event}
    end
  end

  defp get(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp deleted?(message) do
    get(message, :status) == "deleted" or not is_nil(get(message, :deleted_at))
  end

  defp normalise(message) do
    %{
      conversation_id: get(message, :conversation_id),
      message_id: get(message, :message_id),
      sender_user_id: get(message, :sender_user_id),
      message_type: get(message, :message_type),
      body: get(message, :body),
      created_at: get(message, :created_at),
      metadata: get(message, :metadata) || %{}
    }
  end

  defp content_type(%{metadata: metadata}) when is_map(metadata),
    do: metadata["content_type"] || metadata[:content_type]

  defp content_type(_), do: nil
end
