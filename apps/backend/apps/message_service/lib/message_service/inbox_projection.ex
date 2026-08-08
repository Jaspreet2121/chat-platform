defmodule MessageService.InboxProjection do
  @moduledoc """
  Write-side maintenance of the DENORMALISED INBOX ROW (086): `conversations.last_message_*` and
  `conversation_participants.unread_count / oldest_unread_at`. The inbox's @inbox_sql reads these
  instead of running per-user laterals over `messages` — which is both the store-agnostic speedup for
  the app's most-used screen and the removal of §0.5's cross-service dependency before the Scylla port.

  THE SPLIT: preview facts are conversation-GLOBAL (per-user variation is a read-time mask over the
  participant's own prefs — the newest message is always the last to leave any window); only the
  unread counter is per-participant.

  HONESTY RULES for the counter, decided deliberately (do not "fix" these without reading
  DECISION_LOG 2026-08-01):

    * `oldest_unread_at` is NOT advanced on mark_read. Advancing would require a store read per
      receipt to find the next-oldest unread. Left stale it is SAFE: an old watermark merely fails
      @inbox_sql's freshness test and triggers a read-time recount that repairs the row. The one free
      advance: a decrement that reaches 0 NULLs it.
    * Every decrement is clamped at 0 and window-guarded (a read of a message outside the user's
      cleared/auto-delete window was never counted, so it must not decrement).
    * Cross-store drift (once messages live in Scylla) is corrected by the reconciler
      (`ConversationService.InboxReconciler`), which is mandatory, not optional. Under the Postgres
      store these writes share the message transaction, so drift on this path is zero.

  Under the POSTGRES adapter every function here runs inside the caller's transaction. The Scylla
  adapter (when it becomes the store) calls the same functions as separate Postgres writes.
  """

  require Logger

  alias MessageService.Repo

  alias MessageService.VisibilityWindow

  @doc """
  A new message: refresh the conversation's preview columns and increment every OTHER active
  participant's unread. A new message is inside every window by definition (newer than any
  cleared_before, inside any rolling window), so the increment is unconditional — ONE set-based
  UPDATE, not N statements. `oldest_unread_at` only moves backwards-to-set: COALESCE keeps an
  existing older watermark.
  """
  def record_message(%{} = message) do
    created_at = message.created_at

    %{num_rows: preview_rows} =
      Repo.query!(
        "UPDATE conversations SET " <>
          "last_message_id = $2::text::uuid, last_message_at = $3, last_message_body = $4, " <>
          "last_message_type = $5, last_message_content_type = $6, last_message_sender_id = $7::text::uuid " <>
          "WHERE id = $1::text::uuid AND (last_message_at IS NULL OR last_message_at <= $3)",
        [
          message.conversation_id,
          message.message_id,
          created_at,
          message.body,
          message.message_type,
          content_type(message),
          message.sender_user_id
        ]
      )

    # A ZERO-ROW UPDATE IS A SUCCESSFUL UPDATE. `Repo.query!` raises only on a SQL error, so a write
    # rejected by the `last_message_at <= $3` guard is indistinguishable from one that landed, and the
    # preview silently stops tracking the conversation. Nothing downstream can tell either: the
    # consumer commits on `{:ok, _}` and the ledger row looks identical.
    #
    # This is not a "maybe out-of-order replay" false alarm. Events are keyed by `conversation_id`
    # with a `:hash` partitioner, so every event for a conversation lands on ONE partition and is
    # consumed in order; and a redelivery is stopped by the ledger before it reaches this function.
    # Within a conversation, an older `created_at` arriving after a newer one should not happen — so
    # zero rows here means either that assumption broke or the conversation row is gone. Log, do not
    # raise: this runs inside the consumer's transaction on a live path, and a stale preview is not
    # worth failing an event over.
    if preview_rows == 0 do
      Logger.warning(
        "inbox preview write matched ZERO rows — preview NOT updated. " <>
          "conversation=#{message.conversation_id} message=#{message.message_id} " <>
          "created_at=#{inspect(created_at)}. Either conversations.last_message_at is NEWER than " <>
          "this message (something else is writing it) or the conversation row is missing."
      )
    end

    Repo.query!(
      "UPDATE conversation_participants SET " <>
        "unread_count = unread_count + 1, oldest_unread_at = COALESCE(oldest_unread_at, $3) " <>
        "WHERE conversation_id = $1::text::uuid AND left_at IS NULL AND user_id <> $2::text::uuid",
      [message.conversation_id, message.sender_user_id, created_at]
    )

    :ok
  end

  @doc "A body edit: the preview text changes only when the edited message IS the preview."
  def record_edit(%{} = message) do
    Repo.query!(
      "UPDATE conversations SET last_message_body = $3 " <>
        "WHERE id = $1::text::uuid AND last_message_id = $2::text::uuid",
      [message.conversation_id, message.message_id, message.body]
    )

    :ok
  end

  @doc """
  A delete-for-everyone: (1) decrement unread for every participant who had NOT read it — window-
  guarded per row, since the lateral this replaces only counted messages inside each user's window;
  (2) if the deleted message was the preview, recompute the preview from the store (next newest
  non-deleted — an adapter-local read: under Postgres this query, under Scylla its own list read).
  `oldest_unread_at` may go stale here when the deleted message WAS the oldest unread — deliberately
  left (see the moduledoc honesty rules): stale fails the freshness test and self-corrects.
  """
  def record_delete(%{} = message) do
    Repo.query!(
      "UPDATE conversation_participants cp SET " <>
        "unread_count = GREATEST(cp.unread_count - 1, 0), " <>
        "oldest_unread_at = CASE WHEN GREATEST(cp.unread_count - 1, 0) = 0 THEN NULL ELSE cp.oldest_unread_at END " <>
        "WHERE cp.conversation_id = $1::text::uuid AND cp.left_at IS NULL " <>
        "AND cp.user_id <> $2::text::uuid " <>
        "AND " <>
        VisibilityWindow.participant_window_sql("cp", "$4") <>
        " " <>
        "AND NOT EXISTS (SELECT 1 FROM message_receipts r " <>
        "  WHERE r.conversation_id = cp.conversation_id AND r.message_id = $3::text::uuid " <>
        "  AND r.user_id = cp.user_id AND (r.status = 'read' OR r.read_at IS NOT NULL))",
      [message.conversation_id, message.sender_user_id, message.message_id, message.created_at]
    )

    refresh_preview_if_last(message.conversation_id, message.message_id)
    :ok
  end

  @doc """
  A first-time READ receipt: decrement the reader's counter — guarded by the same window the lateral
  applied, clamped at 0, and NULLing the watermark when the count reaches 0 (the free advance).
  The caller (upsert_receipt) is responsible for the FIRST-TIME check: Postgres receipts are
  authoritative there today, which is what makes this decrement idempotent on the repeat-read path.
  """
  def record_read(conversation_id, reader_user_id, %{} = message) do
    if message.sender_user_id != reader_user_id and is_nil(message.deleted_at) do
      Repo.query!(
        "UPDATE conversation_participants cp SET " <>
          "unread_count = GREATEST(cp.unread_count - 1, 0), " <>
          "oldest_unread_at = CASE WHEN GREATEST(cp.unread_count - 1, 0) = 0 THEN NULL ELSE cp.oldest_unread_at END " <>
          "WHERE cp.conversation_id = $1::text::uuid AND cp.user_id = $2::text::uuid AND cp.left_at IS NULL " <>
          "AND " <> VisibilityWindow.participant_window_sql("cp", "$3"),
        [conversation_id, reader_user_id, message.created_at]
      )
    end

    :ok
  end

  # If the deleted message was the preview, promote the next newest non-deleted message (or clear the
  # columns when none is left). One query + one update, only on the was-the-preview path.
  defp refresh_preview_if_last(conversation_id, deleted_message_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM conversations WHERE id = $1::text::uuid AND last_message_id = $2::text::uuid",
        [conversation_id, deleted_message_id]
      )

    if rows != [] do
      Repo.query!(
        "UPDATE conversations c SET " <>
          "last_message_id = lm.message_id, last_message_at = lm.created_at, " <>
          "last_message_body = lm.body, last_message_type = lm.message_type, " <>
          "last_message_content_type = lm.metadata->>'content_type', last_message_sender_id = lm.sender_user_id " <>
          "FROM (SELECT message_id, created_at, body, message_type, metadata, sender_user_id " <>
          "      FROM messages WHERE conversation_id = $1::text::uuid AND deleted_at IS NULL " <>
          "      ORDER BY created_at DESC LIMIT 1) lm " <>
          "WHERE c.id = $1::text::uuid",
        [conversation_id]
      )
      |> case do
        %{num_rows: 0} ->
          # No non-deleted message left at all — clear the preview.
          Repo.query!(
            "UPDATE conversations SET last_message_id = NULL, last_message_at = NULL, " <>
              "last_message_body = NULL, last_message_type = NULL, " <>
              "last_message_content_type = NULL, last_message_sender_id = NULL " <>
              "WHERE id = $1::text::uuid",
            [conversation_id]
          )

        _ ->
          :ok
      end
    end

    :ok
  end

  defp content_type(%{metadata: metadata}) when is_map(metadata),
    do: metadata["content_type"] || metadata[:content_type]

  defp content_type(_), do: nil
end
