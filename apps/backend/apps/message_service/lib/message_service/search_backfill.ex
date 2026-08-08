defmodule MessageService.SearchBackfill do
  @moduledoc """
  One-off backfill of `message_search` from the AUTHORITATIVE store, by conversation — the
  "rebuildable from Scylla" half of DECISION_LOG [2026-08-08].

  WHY IT EXISTS: the search-index consumer replays the topic from `:earliest`, but messages written
  before Kafka publishing was enabled (or past retention) have no event to replay. Without a
  backfill they return EMPTY results indistinguishable from no matches — the silent-degradation
  shape message-service.md explicitly forbids for this endpoint.

  Run from a release shell / `mix run -e`:

      MessageService.SearchBackfill.run()

  ## Safe to run while the consumer is LIVE, because it never overwrites

  Inserts are `ON CONFLICT DO NOTHING`. The consumer and the edit path write with overwrite
  semantics and always carry the CURRENT body (read-back at consume time); this task's read may be
  seconds older, so it must never win a conflict. Idempotent by primary key — run it twice, nothing
  changes.

  Residual window, stated: a message deleted between this task's store read and its insert leaves
  an index row that no future event deletes (its delete event was consumed before the row existed).
  The row cannot RENDER — hydration reads the tombstone — it is only an unrenderable stub. A re-run
  does not remove it; if that ever matters, the sweep is
  `DELETE FROM message_search s WHERE NOT EXISTS (store row)`, which is a separate decision.

  Conversation ids come from Postgres `conversations` — conversation metadata is Postgres-owned and
  LIVE (it is the inbox), not part of the frozen `messages` table. Nothing here reads Postgres
  `messages`.
  """

  require Logger

  alias MessageService.MessageStore
  alias MessageService.Repo

  @page_limit 100

  @doc "Backfill every conversation. Returns %{conversations, indexed, skipped_existing, deleted}."
  def run do
    %{rows: rows} = Repo.query!("SELECT id::text FROM conversations", [])

    totals =
      Enum.reduce(rows, %{conversations: 0, indexed: 0, skipped_existing: 0, deleted: 0}, fn [id],
                                                                                             acc ->
        merge_counts(%{acc | conversations: acc.conversations + 1}, backfill_conversation(id))
      end)

    Logger.info("search backfill: #{inspect(totals)}")
    totals
  end

  @doc "Backfill one conversation, paging the store with its own cursor. Returns counts."
  def backfill_conversation(conversation_id) do
    page(conversation_id, nil, %{indexed: 0, skipped_existing: 0, deleted: 0})
  end

  defp page(conversation_id, cursor, acc) do
    attrs =
      %{"conversation_id" => conversation_id, "limit" => @page_limit}
      |> then(fn a -> if cursor, do: Map.put(a, "cursor", cursor), else: a end)

    case MessageStore.list_messages(attrs) do
      {:ok, %{messages: []}} ->
        acc

      {:ok, %{messages: messages} = listing} ->
        acc = Enum.reduce(messages, acc, &index_one/2)
        next = Map.get(listing, :next_cursor)

        if is_binary(next) and next != "" and length(messages) >= @page_limit do
          page(conversation_id, next, acc)
        else
          acc
        end

      {:error, reason} ->
        # A conversation the store cannot list (e.g. no Scylla rows at all) contributes nothing.
        # Logged, not raised: one bad conversation must not abort the whole backfill.
        Logger.warning(
          "search backfill: list failed conversation=#{conversation_id}: #{inspect(reason)}"
        )

        acc
    end
  end

  defp index_one(message, acc) do
    cond do
      deleted?(message) ->
        %{acc | deleted: acc.deleted + 1}

      true ->
        %{num_rows: n} =
          Repo.query!(
            "INSERT INTO message_search " <>
              "(message_id, conversation_id, sender_user_id, created_at, search_text) " <>
              "VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, $4, $5) " <>
              "ON CONFLICT (message_id) DO NOTHING",
            [
              get(message, :message_id),
              get(message, :conversation_id),
              get(message, :sender_user_id),
              get(message, :created_at),
              get(message, :body) || ""
            ]
          )

        if n == 1,
          do: %{acc | indexed: acc.indexed + 1},
          else: %{acc | skipped_existing: acc.skipped_existing + 1}
    end
  end

  defp deleted?(message) do
    get(message, :status) == "deleted" or not is_nil(get(message, :deleted_at))
  end

  defp get(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp merge_counts(acc, counts) do
    %{
      acc
      | indexed: acc.indexed + counts.indexed,
        skipped_existing: acc.skipped_existing + counts.skipped_existing,
        deleted: acc.deleted + counts.deleted
    }
  end
end
