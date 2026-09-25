defmodule MessageService.InboxRecount do
  @moduledoc """
  RECOUNT one participant's unread counter from the STORE — never from the Postgres `messages`
  table.

  `ConversationService.InboxCounters.recount/2` is the recount every corrective path calls: a
  rejoin, an auto-delete window moving, a read-repair. Its only implementation was a lateral over
  Postgres `messages`, which stopped receiving writes at the Scylla cutover; run there it would set
  every counter to 0 (the table is empty), so it was interlocked OFF — which meant those paths
  simply did nothing under the live store and a counter that drifted stayed drifted.

  This is the store-backed implementation that interlock was waiting for. The count is defined the
  way the maintained counter is maintained, so a recount agrees with a counter that never drifted:

    * candidates: the conversation's messages, newest first, from `MessageStore.list_messages` —
      the configured adapter, which in production is Scylla — that are NOT the reader's own and
      NOT deleted, and that fall inside the reader's window: after `cleared_before`, inside the
      auto-delete window, and no older than the settlement horizon (a message older than that can
      never be claimed as read, so the counter path could never have decremented it either);
    * minus the ones the reader has ALREADY CLAIMED in `inbox_read_marks` — the projection's own
      exactly-once ledger, which is what "read" means to the counter.

  THE WRITE HAPPENS ONLY ON A COMPLETE ANSWER. A store that cannot be reached, or a conversation so
  long that the walk hits its cap, returns an error and touches nothing: an unknown count is not 0,
  and a recount whose failure mode is "sign everyone's badge to zero" is the bug this replaces.
  """

  alias MessageService.MessageStore
  alias MessageService.Repo

  @page 200
  # A recount reads at most this many rows before giving up. 5,000 unread-window messages in one
  # conversation is not a badge anybody needs exact; an incomplete walk must not write a low number.
  @max_rows 5_000

  @doc "Attr-map entry point for the internal API: \"conversation_id\", \"user_id\"."
  def recount_attrs(attrs) when is_map(attrs) do
    with {:ok, conversation_id} <- required(attrs, "conversation_id"),
         {:ok, user_id} <- required(attrs, "user_id") do
      recount(conversation_id, user_id)
    end
  end

  @doc """
  `{:ok, %{unread_count: n, oldest_unread_at: iso8601 | nil}}` after writing the participant row,
  or `{:error, reason}` with the row untouched.
  """
  def recount(conversation_id, user_id) do
    with {:ok, window} <- window(conversation_id, user_id),
         {:ok, candidates} <- candidates(conversation_id, user_id, window) do
      unread = subtract_read_marks(conversation_id, user_id, candidates)
      oldest = unread |> Enum.map(& &1.created_at) |> Enum.min(DateTime, fn -> nil end)

      Repo.query!(
        "UPDATE conversation_participants SET unread_count = $3, oldest_unread_at = $4 " <>
          "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
        [conversation_id, user_id, length(unread), oldest]
      )

      {:ok,
       %{unread_count: length(unread), oldest_unread_at: oldest && DateTime.to_iso8601(oldest)}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :recount_invalid}
  end

  # The reader's window, from their own participant row. No row → nothing to recount.
  defp window(conversation_id, user_id) do
    case Repo.query!(
           "SELECT cleared_before, auto_delete_seconds FROM conversation_participants " <>
             "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
           [conversation_id, user_id]
         ) do
      %{rows: [[cleared_before, auto_delete_seconds]]} ->
        now = DateTime.utc_now()

        floors =
          [
            cleared_before,
            auto_delete_seconds && DateTime.add(now, -auto_delete_seconds, :second),
            DateTime.add(
              now,
              -MessageService.InboxSettlementPolicy.claim_horizon_days() * 86_400,
              :second
            )
          ]
          |> Enum.reject(&is_nil/1)

        {:ok, Enum.max(floors, DateTime)}

      _ ->
        {:error, :participant_not_found}
    end
  end

  # Newest first, page by page, stopping at the window floor. Every row returned is a candidate.
  defp candidates(conversation_id, user_id, floor),
    do: walk(conversation_id, user_id, floor, nil, [], 0)

  defp walk(_conversation_id, _user_id, _floor, _cursor, _acc, seen) when seen >= @max_rows,
    do: {:error, :recount_unbounded}

  defp walk(conversation_id, user_id, floor, cursor, acc, seen) do
    attrs = %{"conversation_id" => conversation_id, "limit" => @page}
    attrs = if cursor, do: Map.put(attrs, "cursor", cursor), else: attrs

    case MessageStore.list_messages(attrs) do
      {:ok, %{messages: messages} = page} ->
        {inside, past_floor?} = split_at_floor(messages, floor)

        keep =
          Enum.filter(inside, fn m ->
            to_string(m.sender_user_id) != user_id and is_nil(m.deleted_at) and
              not is_nil(m.created_at)
          end)

        acc = acc ++ keep
        next = Map.get(page, :next_cursor)

        cond do
          past_floor? or messages == [] or is_nil(next) -> {:ok, acc}
          true -> walk(conversation_id, user_id, floor, next, acc, seen + length(messages))
        end

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :message_unavailable}
    end
  end

  # Messages are newest-first, so the first one at or before the floor ends the walk.
  defp split_at_floor(messages, floor) do
    {inside, rest} =
      Enum.split_while(messages, fn m ->
        is_nil(m.created_at) or DateTime.compare(m.created_at, floor) == :gt
      end)

    {inside, rest != []}
  end

  # The projection's own read ledger: a candidate with a mark has been counted down already.
  defp subtract_read_marks(_conversation_id, _user_id, []), do: []

  defp subtract_read_marks(conversation_id, user_id, candidates) do
    ids = Enum.map(candidates, &to_string(&1.message_id))

    %{rows: rows} =
      Repo.query!(
        "SELECT message_id::text FROM inbox_read_marks " <>
          "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid " <>
          "AND message_id::text = ANY($3)",
        [conversation_id, user_id, ids]
      )

    marked = MapSet.new(rows, fn [id] -> id end)
    Enum.reject(candidates, &MapSet.member?(marked, to_string(&1.message_id)))
  end

  defp required(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :recount_invalid}
    end
  end
end
