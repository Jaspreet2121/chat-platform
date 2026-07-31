defmodule ConversationService.InboxCounters do
  @moduledoc """
  Recount + reconciliation for the DENORMALISED INBOX ROW (086). The maintained counters are exact on
  the happy paths (they share the message transaction under the Postgres store), but three things
  legitimately invalidate them and get a targeted recount instead of write-path bookkeeping:

    * a participant's WINDOW changes under existing unread (set_auto_delete);
    * a participant REJOINS after an absence during which nothing was maintained for them;
    * the read-time freshness test fails (auto-delete window moved past `oldest_unread_at`) —
      @inbox_sql recounts inline and calls `repair/3` to write the corrected row back.

  The recount SQL is the OLD unread lateral, run once for one (conversation, user) — this module is
  the ONE remaining place inbox code reads `messages`, and its relocation behind the message-store
  boundary is C7's job (when receipts/messages move to Scylla, this becomes a store recount call).

  `ConversationService.InboxReconciler` runs `reconcile_conversation/1` periodically as the mandatory
  drift backstop (cross-store partial failures, double-delivery decrements — see InboxProjection).
  """

  alias ConversationService.Repo

  @unread_select """
  SELECT count(m.message_id)::int, min(m.created_at)
  FROM messages m
  WHERE m.conversation_id = $1::text::uuid
    AND m.deleted_at IS NULL
    AND m.sender_user_id <> $2::text::uuid
    AND (cp.cleared_before IS NULL OR m.created_at > cp.cleared_before)
    AND (cp.auto_delete_seconds IS NULL
         OR m.created_at > now() - make_interval(secs => cp.auto_delete_seconds))
    AND NOT EXISTS (
      SELECT 1 FROM message_receipts r
      WHERE r.conversation_id = m.conversation_id AND r.message_id = m.message_id
        AND r.user_id = $2::text::uuid AND (r.status = 'read' OR r.read_at IS NOT NULL)
    )
  """

  @doc "Recompute one participant's counter + watermark from source truth."
  def recount(conversation_id, user_id) do
    Repo.query!(
      "UPDATE conversation_participants cp SET (unread_count, oldest_unread_at) = (#{@unread_select}) " <>
        "WHERE cp.conversation_id = $1::text::uuid AND cp.user_id = $2::text::uuid",
      [conversation_id, user_id]
    )

    :ok
  end

  @doc """
  Read-repair callback for @inbox_sql's freshness-exception path: the query already computed the
  correct count inline; persist it and refresh the watermark so the exception stops firing.
  """
  def repair(conversation_id, user_id, _correct_count), do: recount(conversation_id, user_id)

  @doc """
  Reconcile a whole conversation: every active participant's counter, plus the conversation's
  last_message_* columns (preview drift matters as much as counter drift). Used by the reconciler and
  directly by tests.
  """
  def reconcile_conversation(conversation_id) do
    Repo.query!(
      "UPDATE conversation_participants cp SET (unread_count, oldest_unread_at) = " <>
        "(SELECT count(m.message_id)::int, min(m.created_at) FROM messages m " <>
        " WHERE m.conversation_id = cp.conversation_id AND m.deleted_at IS NULL " <>
        "   AND m.sender_user_id <> cp.user_id " <>
        "   AND (cp.cleared_before IS NULL OR m.created_at > cp.cleared_before) " <>
        "   AND (cp.auto_delete_seconds IS NULL " <>
        "        OR m.created_at > now() - make_interval(secs => cp.auto_delete_seconds)) " <>
        "   AND NOT EXISTS (SELECT 1 FROM message_receipts r " <>
        "     WHERE r.conversation_id = m.conversation_id AND r.message_id = m.message_id " <>
        "       AND r.user_id = cp.user_id AND (r.status = 'read' OR r.read_at IS NOT NULL))) " <>
        "WHERE cp.conversation_id = $1::text::uuid AND cp.left_at IS NULL",
      [conversation_id]
    )

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

    :ok
  end

  @doc """
  One reconciler pass: conversations with activity inside `lookback` seconds, up to `limit`.
  Returns how many were reconciled.
  """
  def reconcile_recent(lookback_seconds \\ 3_600, limit \\ 200) do
    %{rows: rows} =
      Repo.query!(
        "SELECT id::text FROM conversations " <>
          "WHERE last_message_at > now() - make_interval(secs => $1) " <>
          "ORDER BY last_message_at DESC LIMIT $2",
        [lookback_seconds, limit]
      )

    Enum.each(rows, fn [id] -> reconcile_conversation(id) end)
    length(rows)
  end
end
