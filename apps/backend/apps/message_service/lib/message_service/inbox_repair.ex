defmodule MessageService.InboxRepair do
  @moduledoc """
  ONE-OFF repair of the inbox rows the reconciler froze. EXECUTED against production on 2026-08-08
  (audit file `inbox_repair_20260808_184656`): 335 previews cleared, 5 rewritten from the store,
  0 drift skips, 356 unread rows zeroed; the post-run verify query found 0 stale unread rows and
  only the 5 rewritten conversations still pre-boundary — correctly, see below. It stays in the
  repo as the record of what was run, not as a tool. IT MUST NEVER GROW A SCHEDULE OR A SWEEP — a
  recurring recount is exactly the thing `ConversationService.InboxCounters`' interlock exists to
  prevent.

  AFTER THE FROZEN `messages` TABLE IS TRUNCATED (DECISION_LOG [2026-08-09], the table's-end entry),
  `boundary/0` returns nil and `run/0` prints "no boundary, nothing to do" — this tool can then
  never run again, and that is fine: it is sealed, and its audit file is the record.

  ## What it repairs, and why the damage exists

  Between the Scylla cutover (2026-08-08 ~11:01 UTC) and the reconciler gate (80545d2),
  `InboxCounters`' reconciler rewrote `conversations.last_message_*` and
  `conversation_participants.unread_count`/`oldest_unread_at` from the FROZEN Postgres `messages`
  table every 300 seconds, overwriting the topic projection's correct writes. Conversations active
  since then self-healed (the projection's guard passes and rewrites the whole set); ~340 quiet
  test-era conversations show frozen data forever, and a corrupted unread BASE survives even on
  self-healed conversations because the increment `COALESCE`s the old watermark.

  ## "Provably stale", precisely

  `boundary := (SELECT max(created_at) FROM messages)` — the frozen table's own newest row
  (measured in production: 2026-08-08 11:00:35 UTC, just before the flip). The reconciler computed
  from that table, so every value it ever wrote is `<= boundary` BY CONSTRUCTION; the projection's
  own guard (`last_message_at <= $3`) means its post-cutover writes only ever moved the preview
  FORWARD past it. Therefore:

    * preview stale:  `last_message_at IS NOT NULL AND last_message_at <= boundary`
    * unread stale:   `oldest_unread_at IS NOT NULL AND oldest_unread_at <= boundary`

  A conversation the projection has since rewritten fails the predicate and is untouched. The
  predicate is re-checked INSIDE every UPDATE (not only in the planning SELECT), so a live event
  racing this repair wins: the consumer writes a post-boundary value and the repair's UPDATE
  matches zero rows.

  ## What each stale row gets

    * PREVIEW, store empty (no `message_search` rows for the conversation): CLEARED — all six
      `last_message_*` columns NULL, the projection's own "no live message left" semantics. The
      list then matches what opening the chat shows. All pre-cutover data is test data; nothing
      real is lost.
    * PREVIEW, store non-empty: REWRITTEN from the authoritative store — newest live message found
      via `message_search` in SQL, then ONE point read (`MessageStore.get_message`, bucket derived)
      for the fields the index deliberately does not store (`message_type`, metadata content_type)
      and to confirm it is not tombstoned. A drifted newest hit (index row whose store row is gone)
      is SKIPPED and reported, never guessed at.
    * UNREAD: ZEROED, watermark NULLed — option (b), decided 2026-08-08: every pre-cutover message
      is test data, so the frozen contribution is worthless, and the recount alternative was
      rejected as more machinery for data nobody will miss. Known, accepted cost: a stale-watermark
      row that ALSO accumulated real post-cutover unread loses that count too (it re-accumulates
      only via new messages).

  ## Running it

      MessageService.InboxRepair.run()                  # DRY RUN: plans + audit file, writes nothing
      MessageService.InboxRepair.run(dry_run: false)    # executes

  Stdout gets summary counts only; the full before/after audit (one line per row, bodies truncated)
  goes to a timestamped file — `path:` overrides, default under `System.tmp_dir/`.

  ## Idempotency — how each path converges to zero

  Clears and unread zeroes leave the stale predicate (NULLed columns), so a re-run plans none.
  Rewrites CANNOT leave it that way: a correct preview whose newest live message predates the
  boundary keeps a pre-boundary `last_message_at` forever — the production run's five dual-write-era
  conversations are exactly this shape, and the first version of this module re-planned them on
  every run (harmless same-value writes, but the claim of zero was false; caught by the operator's
  second dry run, 2026-08-08). The rewrite planner therefore carries a no-op detector: a
  conversation whose `last_message_id` already points at the store's newest indexed message plans
  nothing. Safe because the reconciler wrote all six columns from the SAME message the store holds
  (dual-write era rows exist identically in both stores), so id-equality implies value-equality.
  """

  alias MessageService.MessageStore
  alias MessageService.Repo

  @doc "Plan (and unless `dry_run: false`, only plan) the repair. Returns the summary map."
  def run(opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, true)
    path = Keyword.get(opts, :path, default_path())

    case boundary() do
      nil ->
        # No frozen rows at all → nothing is provable and nothing can be stale by this definition.
        IO.puts("inbox repair: messages table is empty — no boundary, nothing to do")
        %{dry_run: dry_run, boundary: nil}

      boundary ->
        {clears, rewrites, skips} = repair_previews(boundary, dry_run)
        unread = repair_unread(boundary, dry_run)

        lines =
          Enum.map(clears, &clear_line/1) ++
            Enum.map(rewrites, &rewrite_line/1) ++
            Enum.map(skips, &skip_line/1) ++ Enum.map(unread, &unread_line/1)

        File.write!(path, audit_header(boundary, dry_run) <> Enum.join(lines, "\n") <> "\n")

        summary = %{
          dry_run: dry_run,
          boundary: boundary,
          previews_cleared: length(clears),
          previews_rewritten: length(rewrites),
          skipped_drift: length(skips),
          unread_zeroed: length(unread),
          audit_file: path
        }

        IO.puts("inbox repair #{if dry_run, do: "DRY RUN (nothing written)", else: "EXECUTED"}")
        IO.puts("  boundary:           #{inspect(boundary)}")
        IO.puts("  previews cleared:   #{summary.previews_cleared}")
        IO.puts("  previews rewritten: #{summary.previews_rewritten}")
        IO.puts("  skipped (drift):    #{summary.skipped_drift}")
        IO.puts("  unread zeroed:      #{summary.unread_zeroed}")
        IO.puts("  audit: #{path}")
        summary
    end
  end

  @doc false
  def boundary do
    %{rows: [[ts]]} = Repo.query!("SELECT max(created_at) FROM messages", [])
    ts
  end

  # --- previews ------------------------------------------------------------------------------------

  defp repair_previews(boundary, dry_run) do
    clears = clear_empty_store_previews(boundary, dry_run)
    {rewrites, skips} = rewrite_from_store(boundary, dry_run)
    {clears, rewrites, skips}
  end

  # ONE set-based statement: every stale preview whose conversation has NOTHING in the live store's
  # copy. The stale predicate is inside the UPDATE, and prev is a same-statement snapshot so the
  # audit carries true before-values.
  defp clear_empty_store_previews(boundary, dry_run) do
    stale = "c.last_message_at IS NOT NULL AND c.last_message_at <= $1"
    no_store = "NOT EXISTS (SELECT 1 FROM message_search s WHERE s.conversation_id = c.id)"

    sql =
      if dry_run do
        "SELECT c.id::text, c.last_message_at, left(c.last_message_body, 30) " <>
          "FROM conversations c WHERE #{stale} AND #{no_store}"
      else
        "UPDATE conversations c SET last_message_id = NULL, last_message_at = NULL, " <>
          "last_message_body = NULL, last_message_type = NULL, " <>
          "last_message_content_type = NULL, last_message_sender_id = NULL " <>
          "FROM (SELECT id, last_message_at, left(last_message_body, 30) AS body " <>
          "      FROM conversations) prev " <>
          "WHERE prev.id = c.id AND #{stale} " <>
          "AND #{no_store} " <>
          "RETURNING c.id::text, prev.last_message_at, prev.body"
      end

    %{rows: rows} = Repo.query!(sql, [boundary])
    rows
  end

  # The minority with live store data: newest candidate per conversation from message_search (SQL),
  # hydrated by ONE point read each for type/content_type and the tombstone check. Runtime bound:
  # one point read per such conversation — a handful at the measured blast radius (Scylla holds ~36
  # messages total against 340 stale previews), worst case 340 × ~5ms ≈ seconds.
  defp rewrite_from_store(boundary, dry_run) do
    # The inner query picks each stale conversation's NEWEST index row; the OUTER filter is the
    # no-op detector: a preview already pointing at that newest message is already correct, so it
    # plans nothing and a re-run converges to zero. The filter must sit OUTSIDE the DISTINCT ON —
    # inside the WHERE it would drop the newest row and let the second-newest through, planning a
    # backwards rewrite for exactly the rows that need none.
    %{rows: candidates} =
      Repo.query!(
        "SELECT * FROM (" <>
          "SELECT DISTINCT ON (s.conversation_id) " <>
          "s.conversation_id::text AS conversation_id, s.message_id::text AS message_id, " <>
          "c.last_message_id::text AS current_id, c.last_message_at, " <>
          "left(c.last_message_body, 30) AS body " <>
          "FROM message_search s JOIN conversations c ON c.id = s.conversation_id " <>
          "WHERE c.last_message_at IS NOT NULL AND c.last_message_at <= $1 " <>
          "ORDER BY s.conversation_id, s.created_at DESC" <>
          ") newest WHERE newest.current_id IS DISTINCT FROM newest.message_id",
        [boundary]
      )

    Enum.reduce(candidates, {[], []}, fn [
                                           conversation_id,
                                           message_id,
                                           _current_id,
                                           before_at,
                                           before_body
                                         ],
                                         {rewrites, skips} ->
      case live_store_message(conversation_id, message_id) do
        {:ok, message} ->
          unless dry_run, do: write_preview(conversation_id, message, boundary)
          {[{conversation_id, before_at, before_body, message} | rewrites], skips}

        :absent ->
          # Index drift (a row the store no longer has). Do NOT clear on this evidence — the index
          # said data exists and one absent newest is not proof of emptiness. Report; the frozen
          # preview stays until a human looks.
          {rewrites, [{conversation_id, message_id, before_at} | skips]}
      end
    end)
  end

  defp live_store_message(conversation_id, message_id) do
    case MessageStore.get_message(%{
           "conversation_id" => conversation_id,
           "message_id" => message_id
         }) do
      {:ok, %{} = message} ->
        deleted = get(message, :status) == "deleted" or not is_nil(get(message, :deleted_at))
        if deleted, do: :absent, else: {:ok, message}

      _ ->
        :absent
    end
  end

  defp write_preview(conversation_id, message, boundary) do
    # The stale predicate re-checked HERE is the race guard: if the projection wrote a newer preview
    # between planning and this statement, zero rows match and the consumer's write wins.
    Repo.query!(
      "UPDATE conversations SET last_message_id = $2::text::uuid, last_message_at = $3, " <>
        "last_message_body = $4, last_message_type = $5, last_message_content_type = $6, " <>
        "last_message_sender_id = $7::text::uuid " <>
        "WHERE id = $1::text::uuid AND last_message_at IS NOT NULL AND last_message_at <= $8",
      [
        conversation_id,
        get(message, :message_id),
        get(message, :created_at),
        get(message, :body),
        get(message, :message_type),
        content_type(message),
        get(message, :sender_user_id),
        boundary
      ]
    )

    :ok
  end

  # --- unread --------------------------------------------------------------------------------------

  # Option (b), one set-based statement. prev is the same-statement snapshot for the audit; the
  # stale predicate is re-checked in the outer WHERE (the race guard).
  defp repair_unread(boundary, dry_run) do
    stale = "cp.oldest_unread_at IS NOT NULL AND cp.oldest_unread_at <= $1"

    sql =
      if dry_run do
        "SELECT cp.conversation_id::text, cp.user_id::text, cp.unread_count, cp.oldest_unread_at " <>
          "FROM conversation_participants cp WHERE #{stale}"
      else
        "UPDATE conversation_participants cp SET unread_count = 0, oldest_unread_at = NULL " <>
          "FROM (SELECT conversation_id, user_id, unread_count, oldest_unread_at " <>
          "      FROM conversation_participants) prev " <>
          "WHERE prev.conversation_id = cp.conversation_id AND prev.user_id = cp.user_id " <>
          "AND #{stale} " <>
          "RETURNING cp.conversation_id::text, cp.user_id::text, prev.unread_count, " <>
          "prev.oldest_unread_at"
      end

    %{rows: rows} = Repo.query!(sql, [boundary])
    rows
  end

  # --- audit ---------------------------------------------------------------------------------------

  defp audit_header(boundary, dry_run) do
    "# inbox repair #{if dry_run, do: "DRY RUN", else: "EXECUTED"} at #{DateTime.utc_now()}\n" <>
      "# boundary (frozen messages max created_at): #{inspect(boundary)}\n" <>
      "# bodies truncated to 30 chars\n"
  end

  defp clear_line([id, at, body]),
    do:
      "PREVIEW CLEAR conv=#{id} before_at=#{inspect(at)} before_body=#{inspect(body)} -> NULL (store empty)"

  defp rewrite_line({id, before_at, before_body, message}) do
    "PREVIEW SET   conv=#{id} before_at=#{inspect(before_at)} before_body=#{inspect(before_body)} " <>
      "-> at=#{inspect(get(message, :created_at))} body=#{inspect(truncate(get(message, :body)))} (from store)"
  end

  defp skip_line({id, message_id, before_at}),
    do:
      "SKIP DRIFT    conv=#{id} newest index row #{message_id} absent in store; frozen preview " <>
        "left (before_at=#{inspect(before_at)})"

  defp unread_line([conversation_id, user_id, count, watermark]),
    do:
      "UNREAD ZERO   conv=#{conversation_id} user=#{user_id} before=#{count} " <>
        "watermark=#{inspect(watermark)} -> 0/NULL"

  defp default_path do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d_%H%M%S")
    Path.join(System.tmp_dir!(), "inbox_repair_#{stamp}.log")
  end

  defp truncate(nil), do: nil
  defp truncate(body) when is_binary(body), do: String.slice(body, 0, 30)

  defp content_type(message) do
    case get(message, :metadata) do
      %{} = metadata -> metadata["content_type"] || metadata[:content_type]
      _ -> nil
    end
  end

  defp get(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end
