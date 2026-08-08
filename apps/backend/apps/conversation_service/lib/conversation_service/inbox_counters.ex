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

  ## EVERY QUERY HERE IS STORE-BOUND, AND THE STORE MOVED

  `@unread_select` and `reconcile_conversation/1`'s preview subquery both read the Postgres
  `messages` table. Under `MESSAGE_STORE_ADAPTER=scylla` that table stops receiving writes, so these
  statements do not merely go stale — they OVERWRITE correct maintained rows with pre-cutover data.
  Observed in production on 2026-08-08: the reconciler reverted a conversation's preview to a
  week-old message and reset `unread_count`/`oldest_unread_at` from the frozen table, every 300
  seconds, silently, while writes and reads were healthy.

  So `postgres_authoritative?/0` gates all three entry points. It is the MIRROR of the interlock in
  `MessageService.Projections.InboxFromTopic`, which refuses to run while the store IS Postgres.
  Together they mean exactly one writer maintains the inbox row in any configuration.

  IT FAILS CLOSED. An unknown backend is treated as "not Postgres" and nothing runs, because the
  failure mode of running wrongly is silent corruption of live data, while the failure mode of not
  running is bounded, visible staleness. Every skip logs.

  The gate is HERE, on the functions, and not on the reconciler's supervisor child or timer, because
  the reconciler is only ONE of four callers — see `recount/2`.
  """

  require Logger

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

  @doc """
  Recompute one participant's counter + watermark from source truth.

  FOUR CALLERS, which is why the gate is on this function rather than on the reconciler:
  `InboxReconciler` (periodic), the inbox read-repair in `Conversations` (via `repair/3`),
  `Participants.set_auto_delete` (the window moved), and `ParticipantStore` (a rejoin). Gating the
  reconciler alone would leave three live paths still recounting from a frozen table — one of them
  on a READ.
  """
  def recount(conversation_id, user_id) do
    if postgres_authoritative?() do
      do_recount(conversation_id, user_id)
    else
      skip("recount", "conversation=#{conversation_id} user=#{user_id}")
    end
  end

  defp do_recount(conversation_id, user_id) do
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
    if postgres_authoritative?() do
      do_reconcile_conversation(conversation_id)
    else
      skip("reconcile_conversation", "conversation=#{conversation_id}")
    end
  end

  defp do_reconcile_conversation(conversation_id) do
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
    if postgres_authoritative?() do
      do_reconcile_recent(lookback_seconds, limit)
    else
      # Gated here as well as per-conversation so the selector scan does not run 200 times to reach
      # 200 no-ops. Returns 0 reconciled, which is the truth.
      skip("reconcile_recent", "lookback=#{lookback_seconds}s")
      0
    end
  end

  defp do_reconcile_recent(lookback_seconds, limit) do
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

  @doc """
  Is the Postgres `messages` table still the authoritative message store?

  Reads `:shared_infra, :message_store_backend`, published by `runtime.exs` from
  `MESSAGE_STORE_ADAPTER` for every container that receives it. `:shared_infra` is in every release;
  `:message_service` is not, so its config would be invisible here and this MUST NOT read it.

  UNKNOWN IS NOT POSTGRES. A container that never received the variable cannot claim the Postgres
  tables are authoritative, and guessing "yes" is what corrupts live rows. `dual_write` counts as
  authoritative — Postgres is still written on that rung; `shadow_read`, `scylla_read` and `scylla`
  do not.
  """
  def postgres_authoritative? do
    Application.get_env(:shared_infra, :message_store_backend) in ["postgres", "dual_write"]
  end

  defp skip(what, context) do
    Logger.warning(
      "inbox #{what}: SKIPPED — Postgres `messages` is not the authoritative store " <>
        "(:shared_infra, :message_store_backend = " <>
        "#{inspect(Application.get_env(:shared_infra, :message_store_backend))}). " <>
        "Recounting from it would overwrite maintained rows with pre-cutover data. #{context}"
    )

    :ok
  end
end
