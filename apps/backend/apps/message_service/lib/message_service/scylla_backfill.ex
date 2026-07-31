defmodule MessageService.ScyllaBackfill do
  @moduledoc """
  Backfill + VERIFICATION for the dual-write window (C7). The report is the deliverable; the backfill
  is just how the data gets there.

  ## Race discipline (backfill vs live dual-write)

  Both paths write the SAME primary keys with values derived from the SAME authority (the Postgres
  row), and every write is a keyed upsert — so any interleaving converges to the authority's state
  EXCEPT one window: backfill reads a row, a live edit lands (mirror writes the new state), backfill
  writes its STALE read back. No cheap CQL conditional closes that window; instead the discipline is
  VERIFY-THEN-RECOPY: `verify/2` field-diffs against the authority and `run/1`-style recopy of any
  divergent row; a second pass converges because the recopy happens-after the edit. The race test
  proves this with concurrent writers, not reasoning.

  Cursor: keyset pagination per conversation on (created_at, message_id) — new messages land AHEAD of
  the cursor (later created_at) via the live mirror, behind it they were already copied; either way
  the row is written by at least one path from authority state.

  ## The verification report — who, when, what gates C8

  Run by the OPERATOR from a remote console on the message service, after backfill completes, during
  steady traffic:

      MessageService.ScyllaBackfill.report()

  Per-conversation message counts (Postgres vs Scylla) + a 1% field-diff sample + unresolved mirror
  failures. Rows younger than the IN-FLIGHT HORIZON (#{300}s) are excluded from the gate — a shadow
  task or sweeper simply may not have run yet; that is lag, not divergence.

  THE GATE FOR C8: `stale_diffs == 0 AND unresolved_failures == 0` on TWO consecutive reports at
  least 10 minutes apart. A diff that appears in both reports with the same message_id is REAL
  divergence (investigate before proceeding); one that appears once and vanishes was in-flight lag.
  """

  require Logger

  alias MessageService.Persistence.MediaProjections
  alias MessageService.Persistence.MessageTimelineWrites
  alias MessageService.Persistence.ScyllaCodec
  alias MessageService.Repo

  @in_flight_horizon_seconds 300
  @page 500

  # --- backfill ------------------------------------------------------------------------------------

  @doc "Backfill every conversation (or the given ids). Returns %{conversations: n, messages: n}."
  def run(conversation_ids \\ nil) do
    ids = conversation_ids || all_conversation_ids()

    totals =
      Enum.reduce(ids, %{conversations: 0, messages: 0}, fn conversation_id, acc ->
        copied = backfill_conversation(conversation_id)
        %{conversations: acc.conversations + 1, messages: acc.messages + copied}
      end)

    Logger.info("scylla backfill: #{totals.conversations} conversations, #{totals.messages} messages")
    totals
  end

  @doc "Copy one conversation's messages (keyset cursor, upserts — safe to rerun anytime)."
  def backfill_conversation(conversation_id) do
    stream_pages(conversation_id, nil, 0)
  end

  defp stream_pages(conversation_id, cursor, copied) do
    rows = page(conversation_id, cursor)

    if rows == [] do
      copied
    else
      Enum.each(rows, &copy_row/1)
      last = List.last(rows)
      stream_pages(conversation_id, {last.created_at, last.message_id}, copied + length(rows))
    end
  end

  defp page(conversation_id, nil) do
    fetch_page(
      "SELECT message_id::text, conversation_id::text, sender_user_id::text, message_type, body, " <>
        "media_id::text, reply_to_message_id::text, status, metadata, created_at, edited_at, deleted_at " <>
        "FROM messages WHERE conversation_id = $1::text::uuid " <>
        "ORDER BY created_at, message_id LIMIT $2",
      [conversation_id, @page]
    )
  end

  defp page(conversation_id, {after_at, after_id}) do
    fetch_page(
      "SELECT message_id::text, conversation_id::text, sender_user_id::text, message_type, body, " <>
        "media_id::text, reply_to_message_id::text, status, metadata, created_at, edited_at, deleted_at " <>
        "FROM messages WHERE conversation_id = $1::text::uuid " <>
        "AND (created_at, message_id) > ($2, $3::text::uuid) " <>
        "ORDER BY created_at, message_id LIMIT $4",
      [conversation_id, after_at, after_id, @page]
    )
  end

  defp fetch_page(sql, params) do
    %{rows: rows} = Repo.query!(sql, params)

    Enum.map(rows, fn [mid, cid, sid, type, body, media, reply, status, metadata, cat, eat, dat] ->
      %{
        message_id: mid,
        conversation_id: cid,
        sender_user_id: sid,
        message_type: type,
        body: body,
        media_id: media,
        reply_to_message_id: reply,
        status: status,
        metadata: metadata || %{},
        created_at: cat,
        edited_at: eat,
        deleted_at: dat
      }
    end)
  end

  defp copy_row(row) do
    attrs = %{
      "conversation_id" => row.conversation_id,
      "bucket_date" => row.created_at |> DateTime.to_date() |> Date.to_iso8601(),
      "message_id" => row.message_id,
      "sender_user_id" => row.sender_user_id,
      "message_type" => row.message_type,
      "body" => row.body,
      "media_id" => row.media_id,
      "reply_to_message_id" => row.reply_to_message_id,
      "status" => row.status,
      "metadata" => row.metadata,
      "created_at" => row.created_at,
      "edited_at" => row.edited_at,
      "deleted_at" => row.deleted_at
    }

    client = client()
    {:ok, _} = exec(client, MessageTimelineWrites.insert_message_plan(attrs))

    if is_binary(row.media_id) and row.media_id != "" do
      {:ok, _} = exec(client, MediaProjections.insert_reference_plan(attrs))

      {:ok, _} =
        exec(
          client,
          MediaProjections.upsert_gallery_plan(
            Map.put(attrs, "deleted", not is_nil(row.deleted_at))
          )
        )
    end

    :ok
  end

  # --- repair (consumes the recorded shadow failures) ----------------------------------------------

  @doc "Re-mirror every unresolved recorded failure from authority state. Returns %{repaired: n, gone: n}."
  def repair_failures do
    %{rows: rows} =
      Repo.query!(
        "SELECT id::text, conversation_id::text, message_id::text FROM scylla_mirror_failures " <>
          "WHERE resolved_at IS NULL ORDER BY inserted_at LIMIT 1000",
        []
      )

    Enum.reduce(rows, %{repaired: 0, gone: 0}, fn [failure_id, conversation_id, message_id], acc ->
      case authority_row(conversation_id, message_id) do
        nil ->
          # The message no longer exists in the authority (should not happen — deletes are soft).
          resolve_failure(failure_id)
          %{acc | gone: acc.gone + 1}

        row ->
          copy_row(row)
          resolve_failure(failure_id)
          %{acc | repaired: acc.repaired + 1}
      end
    end)
  end

  defp authority_row(conversation_id, message_id) do
    case fetch_page(
           "SELECT message_id::text, conversation_id::text, sender_user_id::text, message_type, body, " <>
             "media_id::text, reply_to_message_id::text, status, metadata, created_at, edited_at, deleted_at " <>
             "FROM messages WHERE conversation_id = $1::text::uuid AND message_id = $2::text::uuid",
           [conversation_id, message_id]
         ) do
      [row] -> row
      [] -> nil
    end
  end

  defp resolve_failure(failure_id) do
    Repo.query!(
      "UPDATE scylla_mirror_failures SET resolved_at = now() WHERE id = $1::text::uuid",
      [failure_id]
    )
  end

  # --- verification --------------------------------------------------------------------------------

  @doc """
  Verify one conversation: {count diff, field-diff message ids} — diffs SPLIT by the in-flight
  horizon so lag is never reported as divergence. Recopies nothing itself; `recopy/2` does.
  """
  def verify(conversation_id, opts \\ []) do
    horizon_seconds = Keyword.get(opts, :horizon_seconds, @in_flight_horizon_seconds)
    sample = Keyword.get(opts, :sample, 0.01)
    horizon = DateTime.add(DateTime.utc_now(), -horizon_seconds, :second)

    pg_rows = all_rows(conversation_id)
    scylla_ids = scylla_message_ids(conversation_id, pg_rows)

    {stale_missing, fresh_missing} =
      pg_rows
      |> Enum.reject(&MapSet.member?(scylla_ids, &1.message_id))
      |> Enum.split_with(&(DateTime.compare(&1.created_at, horizon) == :lt))

    sampled = Enum.take_random(pg_rows, max(trunc(length(pg_rows) * sample), 1))

    {stale_field_diffs, fresh_field_diffs} =
      sampled
      |> Enum.filter(&field_diff?/1)
      |> Enum.split_with(&(DateTime.compare(&1.created_at, horizon) == :lt))

    %{
      conversation_id: conversation_id,
      postgres_count: length(pg_rows),
      scylla_count: MapSet.size(scylla_ids),
      stale_diffs: Enum.map(stale_missing ++ stale_field_diffs, & &1.message_id) |> Enum.uniq(),
      in_flight: Enum.map(fresh_missing ++ fresh_field_diffs, & &1.message_id) |> Enum.uniq(),
      sampled: length(sampled)
    }
  end

  @doc "Recopy the given message ids from authority (the verify-then-recopy convergence step)."
  def recopy(conversation_id, message_ids) do
    Enum.each(message_ids, fn message_id ->
      case authority_row(conversation_id, message_id) do
        nil -> :ok
        row -> copy_row(row)
      end
    end)

    :ok
  end

  @doc """
  THE REPORT. Verifies every conversation with recent activity plus any with unresolved failures.
  Gate for C8: stale_diff_total == 0 AND unresolved_failures == 0 on two consecutive reports >= 10
  minutes apart.
  """
  def report(opts \\ []) do
    ids = Keyword.get(opts, :conversation_ids) || all_conversation_ids()
    results = Enum.map(ids, &verify(&1, opts))

    %{rows: [[unresolved]]} =
      Repo.query!(
        "SELECT count(*)::int FROM scylla_mirror_failures WHERE resolved_at IS NULL",
        []
      )

    report = %{
      conversations: length(results),
      postgres_total: results |> Enum.map(& &1.postgres_count) |> Enum.sum(),
      scylla_total: results |> Enum.map(& &1.scylla_count) |> Enum.sum(),
      stale_diff_total: results |> Enum.map(&length(&1.stale_diffs)) |> Enum.sum(),
      in_flight_total: results |> Enum.map(&length(&1.in_flight)) |> Enum.sum(),
      unresolved_failures: unresolved,
      divergent: Enum.filter(results, &(&1.stale_diffs != []))
    }

    Logger.info(
      "scylla verification: pg=#{report.postgres_total} scylla=#{report.scylla_total} " <>
        "STALE_DIFFS=#{report.stale_diff_total} in_flight=#{report.in_flight_total} " <>
        "unresolved_failures=#{report.unresolved_failures} — gate for C8: stale==0 AND " <>
        "unresolved==0 on two reports >=10min apart"
    )

    report
  end

  # --- helpers -------------------------------------------------------------------------------------

  defp all_conversation_ids do
    %{rows: rows} =
      Repo.query!("SELECT DISTINCT conversation_id::text FROM messages", [])

    Enum.map(rows, fn [id] -> id end)
  end

  defp all_rows(conversation_id) do
    collect_pages(conversation_id, nil, [])
  end

  defp collect_pages(conversation_id, cursor, acc) do
    rows = page(conversation_id, cursor)

    if rows == [] do
      acc
    else
      last = List.last(rows)
      collect_pages(conversation_id, {last.created_at, last.message_id}, acc ++ rows)
    end
  end

  # All message ids present in Scylla for the buckets the authority says exist.
  defp scylla_message_ids(conversation_id, pg_rows) do
    buckets =
      pg_rows |> Enum.map(&DateTime.to_date(&1.created_at)) |> Enum.uniq()

    client = client()

    Enum.reduce(buckets, MapSet.new(), fn bucket, acc ->
      case exec(client, list_bucket_ids_plan(conversation_id, bucket)) do
        {:ok, result} ->
          result
          |> rows()
          |> Enum.reduce(acc, fn row, inner -> MapSet.put(inner, row["message_id"]) end)

        _ ->
          acc
      end
    end)
  end

  defp list_bucket_ids_plan(conversation_id, bucket) do
    MessageService.Persistence.QueryPlan.new(
      :verify_bucket_ids,
      "messages_by_conversation",
      "SELECT message_id FROM messages_by_conversation WHERE conversation_id = ? AND bucket_date = ?",
      [ScyllaCodec.encode_uuid(conversation_id), bucket]
    )
  end

  defp field_diff?(pg_row) do
    case MessageService.MessageStore.ScyllaAdapter.get_message(%{
           "conversation_id" => pg_row.conversation_id,
           "message_id" => pg_row.message_id
         }) do
      {:ok, scylla} ->
        scylla.body != pg_row.body or scylla.status != pg_row.status or
          scylla.media_id != pg_row.media_id

      _ ->
        # Missing entirely — already counted by the id diff; not a field diff.
        false
    end
  end

  defp client,
    do: Application.get_env(:message_service, :scylla_client_adapter, SharedInfra.Scylla.Client)

  defp exec(client, plan) do
    case client.execute(plan.statement, plan.params, timeout: 5_000) do
      {:error, reason} -> {:error, reason}
      {:ok, result} -> {:ok, result}
      other -> {:ok, other}
    end
  end

  defp rows(%{rows: rows}) when is_list(rows), do: rows
  defp rows(_), do: []
end
