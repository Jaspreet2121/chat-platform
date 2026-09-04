# PURGE THE LEAKED STATUS MEDIA (2026-09-04 incident) — one-off maintenance, DRY-RUN BY DEFAULT.
#
# WHAT LEAKED. The status sweep used to stamp `media_purged_at` in the SAME statement that selected
# the rows, BEFORE attempting the media delete — and the message release was missing
# MEDIA_CLIENT_ADAPTER=http, so every delete raised (the in-process media client module is not
# bundled in that release) and was rescued to a warning. Result: rows that CLAIM their blob is gone
# ("media_purged_at IS NOT NULL") whose media_assets row is still status='ready' — orphaned MinIO
# objects nothing will ever revisit, because the (since-fixed) sweep skips stamped rows.
#
# WHAT THIS DOES. Selects exactly those rows, re-attempts the removal through the NOW-WORKING http
# media client (owner-scoped, same call the sweep makes), and reports a per-row outcome. IDEMPOTENT:
# a purged asset flips to status='deleted' in media_assets and drops out of the selection, so
# re-running converges to "0 rows" — and a row whose purge fails is reported and left for the next
# run, never marked done.
#
# HOW TO RUN (inside the message container, against the RUNNING node so the http client, repo and
# runtime config are all live — `eval` would boot a cold node):
#
#   dry run (default — prints what WOULD be purged, purges nothing):
#     docker compose -f docker-compose.prod.yml exec -T message \
#       bin/message_service rpc "$(cat scripts/purge_leaked_status_media.exs)"
#
#   apply (same file, explicitly appended apply call):
#     docker compose -f docker-compose.prod.yml exec -T message \
#       bin/message_service rpc "$(cat scripts/purge_leaked_status_media.exs); StatusMediaLeak.run(:apply)"
#
# The module is defined idempotently (defmodule on a running node just reloads it), so the appended
# `run(:apply)` after the file's own dry run is safe: the dry run prints, then apply executes.

defmodule StatusMediaLeak do
  @moduledoc false

  alias MessageService.Repo

  def run(mode \\ :dry_run) when mode in [:dry_run, :apply] do
    rows = leaked_rows()

    IO.puts("== leaked status media: #{length(rows)} row(s) (#{mode}) ==")

    results = Enum.map(rows, &handle_row(&1, mode))

    ok = Enum.count(results, &(&1 == :purged))
    failed = Enum.count(results, &(&1 == :failed))
    skipped = Enum.count(results, &(&1 == :dry_run))

    IO.puts("== done: purged=#{ok} failed=#{failed} dry_run=#{skipped} ==")

    if mode == :dry_run and rows != [] do
      IO.puts("(nothing was changed — append `; StatusMediaLeak.run(:apply)` to the rpc to apply)")
    end

    :ok
  end

  # Stamped-as-purged status rows whose media_assets row is still 'ready' — the leak, precisely.
  # The join is the idempotence: once an asset is purged its status flips to 'deleted' and the row
  # vanishes from this select on the next run.
  defp leaked_rows do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT sp.id::text, sp.media_id::text, sp.app_id::text, sp.owner_user_id::text,
               sp.media_purged_at::text
        FROM status_posts sp
        JOIN media_assets ma ON ma.id = sp.media_id
        WHERE sp.media_purged_at IS NOT NULL
          AND sp.media_id IS NOT NULL
          AND ma.status = 'ready'
        ORDER BY sp.media_purged_at
        """,
        []
      )

    rows
  end

  defp handle_row([status_id, media_id, _app_id, owner_user_id, stamped_at], :dry_run) do
    IO.puts("DRY   status=#{status_id} media=#{media_id} owner=#{owner_user_id} stamped=#{stamped_at}")
    :dry_run
  end

  defp handle_row([status_id, media_id, app_id, owner_user_id, _stamped_at], :apply) do
    case SharedInfra.MediaClient.purge_asset(%{
           "media_id" => media_id,
           "app_id" => app_id,
           "expected_owner_user_id" => owner_user_id
         }) do
      {:ok, %{} = result} ->
        IO.puts("OK    status=#{status_id} media=#{media_id} result=#{inspect(result)}")
        :purged

      other ->
        IO.puts("FAIL  status=#{status_id} media=#{media_id} reason=#{inspect(other)}")
        :failed
    end
  rescue
    error ->
      IO.puts("FAIL  status=#{status_id} media=#{media_id} raised=#{inspect(error)}")
      :failed
  end
end

StatusMediaLeak.run(:dry_run)
