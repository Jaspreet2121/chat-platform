defmodule MessageService.VisibilityWindow do
  @moduledoc """
  THE ONE DEFINITION of "is this message visible to this participant right now".

  A message row can be perfectly alive and still be invisible to a given user, through four
  independent mechanisms that never touch the `messages` row:

    * `cleared_before`        — "clear chat", a one-way per-participant cutoff
    * `auto_delete_seconds`   — a ROLLING per-participant window; messages age out with no write
    * `user_hidden_messages`  — permanent per-user markers (materialised by the read path)
    * `disappear_after_viewing_since` — materialised into the markers above once seen

  This module exists because that predicate was written out longhand in more than one place, and a
  PRIVACY PREDICATE WITH TWO COPIES IS ONE COPY AND ONE FUTURE BUG. `InboxProjection` carried it
  twice; message search omitted it entirely for its whole life, which is how search came to return
  hits for messages the searcher had cleared. Every consumer now composes from here.

  ## Why SQL strings rather than Ecto fragments

  The consumers do not share a query idiom: `InboxProjection` writes raw `UPDATE ... WHERE` against
  `conversation_participants`, search reads with a join to `messages`. What they DO share is the
  boolean condition, and the timestamp it is applied to differs (a bound parameter in the projection,
  a column in search). Emitting the condition as text, parameterised by alias and timestamp
  expression, is the form both can use verbatim. Anything richer would have forced one of them to
  paraphrase, which is the thing being prevented.
  """

  @doc """
  The participant WINDOW condition: true when `timestamp_sql` falls inside this participant's
  cleared/auto-delete window.

    * `cp_alias`     — SQL alias of the `conversation_participants` row (e.g. `"cp"`)
    * `timestamp_sql` — the message timestamp: a bound param (`"$4"`) or a column (`"m.created_at"`)

  NULL-safe in both directions: an absent setting narrows nothing.
  """
  @spec participant_window_sql(String.t(), String.t()) :: String.t()
  def participant_window_sql(cp_alias, timestamp_sql) do
    "(#{cp_alias}.cleared_before IS NULL OR #{timestamp_sql} > #{cp_alias}.cleared_before) " <>
      "AND (#{cp_alias}.auto_delete_seconds IS NULL OR " <>
      "#{timestamp_sql} > now() - make_interval(secs => #{cp_alias}.auto_delete_seconds))"
  end

  @doc """
  The permanent per-user hidden-marker condition: true when this message is NOT hidden for the user.

    * `message_id_sql` — the message id expression (e.g. `"m.message_id"`)
    * `user_param`     — the bound user id param (e.g. `"$1"`), cast text->uuid by the caller's style
  """
  @spec not_hidden_sql(String.t(), String.t()) :: String.t()
  def not_hidden_sql(message_id_sql, user_param) do
    "NOT EXISTS (SELECT 1 FROM user_hidden_messages h " <>
      "WHERE h.user_id = #{user_param}::text::uuid AND h.message_id = #{message_id_sql})"
  end

  @doc """
  The after-viewing condition for a READ path that cannot materialise markers.

  `apply_viewer_window/3` materialises disappear-after-viewing markers when a user opens a
  conversation. A GLOBAL read (search) spans conversations the user has not opened, so those markers
  may not exist yet — and materialising across every conversation would mean a write fan-out on a
  read path. Instead the condition is evaluated INLINE: hide anything created after the setting was
  enabled that this user has already seen (authored it, or has a read receipt for it).

  The marker still gets written later, by the conversation read path, exactly as before. This only
  ensures a global read does not surface something the conversation view would hide.
  """
  @spec seen_under_after_viewing_sql(String.t(), String.t(), String.t()) :: String.t()
  def seen_under_after_viewing_sql(message_alias, cp_alias, user_param) do
    "NOT (#{cp_alias}.disappear_after_viewing_since IS NOT NULL " <>
      "AND #{message_alias}.created_at > #{cp_alias}.disappear_after_viewing_since " <>
      "AND (#{message_alias}.sender_user_id = #{user_param}::text::uuid " <>
      "OR EXISTS (SELECT 1 FROM message_receipts r " <>
      "WHERE r.message_id = #{message_alias}.message_id " <>
      "AND r.user_id = #{user_param}::text::uuid " <>
      "AND (r.status = 'read' OR r.read_at IS NOT NULL))))"
  end
end
