defmodule MessageService.Pins do
  @moduledoc """
  PINNED MESSAGES (092) — per-conversation, up to `max_pins/0`, visible to every participant.

  Not to be confused with `conversation_participants.pinned_at` (076), which is a PER-USER inbox
  preference sorting a chat to the top of your list. Two features, one word; see the migration header.

  WHO CAN PIN is enforced at the GATEWAY, not here — it needs the caller's conversation ROLE, which
  lives in conversation_service. Same split as `only_admins_can_send`: the gateway asks
  conversation_service, then calls this. This module owns the cap, the storage and the masked read.
  """

  alias MessageService.Repo
  alias MessageService.VisibilityWindow

  @max_pins 3

  @doc "Pins allowed per conversation."
  def max_pins, do: @max_pins

  @doc """
  Pin a message. Idempotent — re-pinning an already-pinned message succeeds without consuming budget.

  Refuses `:pin_limit` over the cap, and `:message_not_found` when the message does not exist, is
  soft-deleted, or belongs to a DIFFERENT conversation (checked here so a caller cannot pin a message
  out of a conversation they are not in by supplying someone else's message id).
  """
  def pin_message(attrs) do
    with {:ok, conversation_id} <- required(attrs, "conversation_id"),
         {:ok, message_id} <- required(attrs, "message_id"),
         {:ok, user_id} <- required(attrs, "user_id"),
         :ok <- ensure_live_message(conversation_id, message_id),
         :ok <- ensure_under_cap(conversation_id, message_id) do
      Repo.query!(
        "INSERT INTO message_pins (conversation_id, message_id, pinned_by) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid) " <>
          "ON CONFLICT (conversation_id, message_id) DO NOTHING",
        [conversation_id, message_id, user_id]
      )

      {:ok, %{conversation_id: conversation_id, message_id: message_id, pinned: true}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :pin_invalid}
  end

  @doc "Unpin. Idempotent — unpinning something not pinned succeeds."
  def unpin_message(attrs) do
    with {:ok, conversation_id} <- required(attrs, "conversation_id"),
         {:ok, message_id} <- required(attrs, "message_id") do
      Repo.query!(
        "DELETE FROM message_pins " <>
          "WHERE conversation_id = $1::text::uuid AND message_id = $2::text::uuid",
        [conversation_id, message_id]
      )

      {:ok, %{conversation_id: conversation_id, message_id: message_id, pinned: false}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :pin_invalid}
  end

  @doc """
  The pins a given VIEWER may see, newest pin first.

  ## THE PINNED SET IS GLOBAL; THIS LIST IS MASKED PER USER

  TWO PEOPLE IN THE SAME GROUP CAN LEGITIMATELY SEE DIFFERENT PINNED BARS. That is not a bug.

  IF YOU REMOVE THE MASK BELOW YOU WILL RESURRECT MESSAGES THIS USER CLEARED, OR THAT AUTO-DELETED FOR
  THEM, OR THAT THEY DELETED FOR THEMSELVES — showing them the text of a message they cannot open.
  A pin is per-conversation; `cleared_before`, the rolling `auto_delete_seconds` window and
  `user_hidden_messages` are all per-user, and a pin overrides none of them.

  This exact mistake already shipped once: message search returned hits for cleared and auto-deleted
  messages for its whole life before it was fixed. The predicate is composed from
  `MessageService.VisibilityWindow` so it has one definition, not a paraphrase.

  A soft-deleted message is filtered here too — the unpin-on-delete write path keeps the cap honest,
  and this filter is what makes a missed write path unable to resurrect a tombstone.
  """
  def list_pins(attrs) do
    with {:ok, conversation_id} <- required(attrs, "conversation_id") do
      viewer = get(attrs, "user_id")

      {sql, params} = list_query(conversation_id, viewer)
      %{rows: rows} = Repo.query!(sql, params)

      {:ok,
       %{
         pins:
           Enum.map(rows, fn [message_id, pinned_by, pinned_at] ->
             %{message_id: message_id, pinned_by: pinned_by, pinned_at: pinned_at}
           end)
       }}
    end
  rescue
    Ecto.Query.CastError -> {:error, :pin_invalid}
  end

  # No viewer (admin/system read) → no per-user narrowing, matching how apply_viewer_window/3 treats a
  # nil viewer. Every USER-facing caller supplies one.
  defp list_query(conversation_id, viewer) when not is_binary(viewer) or viewer == "" do
    {"SELECT p.message_id::text, p.pinned_by::text, p.pinned_at " <>
       "FROM message_pins p " <>
       "JOIN messages m ON m.message_id = p.message_id " <>
       "WHERE p.conversation_id = $1::text::uuid AND m.status <> 'deleted' " <>
       "ORDER BY p.pinned_at DESC", [conversation_id]}
  end

  defp list_query(conversation_id, viewer) do
    # THE MASK. See the moduledoc above this function before touching these three lines.
    sql =
      "SELECT p.message_id::text, p.pinned_by::text, p.pinned_at " <>
        "FROM message_pins p " <>
        "JOIN messages m ON m.message_id = p.message_id " <>
        "JOIN conversation_participants cp " <>
        "  ON cp.conversation_id = p.conversation_id " <>
        "  AND cp.user_id = $2::text::uuid " <>
        "  AND cp.left_at IS NULL " <>
        "WHERE p.conversation_id = $1::text::uuid " <>
        "AND m.status <> 'deleted' " <>
        "AND " <>
        VisibilityWindow.participant_window_sql("cp", "m.created_at") <>
        " " <>
        "AND " <>
        VisibilityWindow.not_hidden_sql("m.message_id", "$2") <>
        " " <>
        "AND " <>
        VisibilityWindow.seen_under_after_viewing_sql("m", "cp", "$2") <>
        " " <>
        "ORDER BY p.pinned_at DESC"

    {sql, [conversation_id, viewer]}
  end

  @doc """
  Drop a message's pin — called from the delete path so a deleted message stops occupying pin budget.

  The read filter is the safety net; this is what keeps the CAP honest. Best-effort by design: a
  failure here must never fail the delete, because the read filter already prevents the tombstone
  being shown.
  """
  def unpin_deleted(message_id) when is_binary(message_id) and message_id != "" do
    Repo.query!("DELETE FROM message_pins WHERE message_id = $1::text::uuid", [message_id])
    :ok
  rescue
    _ -> :ok
  end

  def unpin_deleted(_message_id), do: :ok

  # --- guards -------------------------------------------------------------------------------------

  # The message must exist, be live, and belong to THIS conversation. The last clause is the
  # authorization-shaped one: without it a caller could pin a message from a conversation they are not
  # in, because the gateway only checked their role in the conversation named in the URL.
  defp ensure_live_message(conversation_id, message_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM messages " <>
          "WHERE message_id = $1::text::uuid AND conversation_id = $2::text::uuid " <>
          "AND status <> 'deleted'",
        [message_id, conversation_id]
      )

    if rows == [], do: {:error, :message_not_found}, else: :ok
  end

  # Re-pinning something already pinned must NOT count against the cap (the insert is a no-op), so the
  # cap check excludes the target row.
  defp ensure_under_cap(conversation_id, message_id) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*)::int FROM message_pins " <>
          "WHERE conversation_id = $1::text::uuid AND message_id <> $2::text::uuid",
        [conversation_id, message_id]
      )

    if count >= @max_pins, do: {:error, :pin_limit}, else: :ok
  end

  defp required(attrs, key) do
    case get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :pin_invalid}
    end
  end

  defp get(attrs, key) when is_map(attrs),
    do: Map.get(attrs, key) || Map.get(attrs, safe_atom(key))

  defp get(_attrs, _key), do: nil

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> :__missing__
  end
end
