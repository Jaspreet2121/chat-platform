defmodule MediaService.Variants.Backfill do
  @moduledoc """
  Variants for the images uploaded BEFORE 124 — DRY-RUN BY DEFAULT, batches of 50, resumable.

  The work queue is `media_assets` rows that are ready, plain (`purpose <> 'sealed_media'`),
  `image/*`, within the size cap and still `variants IS NULL` — exactly the partial index 124
  creates. Each processed row leaves the queue: on success `variants` is written; on failure it is
  set to `{"failed": {reason, at}}` so a broken source is attempted ONCE here and never again. A run
  interrupted at any point therefore resumes where it stopped, and re-running converges to
  "0 pending". Between batches it pauses (`pause_ms`, default 250) so the 2-vCPU box keeps serving.

  HOW TO RUN (inside the media container, against the RUNNING node — storage config and repo live):

      # dry run (default): counts the queue, touches nothing
      docker compose -f docker-compose.prod.yml exec -T media \\
        bin/media_service rpc "MediaService.Variants.Backfill.run()"

      # apply, at most 500 assets this invocation (re-run to continue)
      docker compose -f docker-compose.prod.yml exec -T media \\
        bin/media_service rpc "MediaService.Variants.Backfill.run(apply: true, limit: 500)"

  Answers `%{pending: n, processed: n, generated: n, failed: n, dry_run: bool}`.
  """

  require Logger
  import Ecto.Query, only: [from: 2]

  alias MediaService.Repo
  alias MediaService.Schemas.MediaAsset
  alias MediaService.Variants

  @batch 50

  @doc "See the moduledoc. Options: `apply: false`, `limit: nil` (all), `pause_ms: 250`, `batch: 50`."
  def run(opts \\ []) do
    apply? = Keyword.get(opts, :apply, false)
    limit = Keyword.get(opts, :limit)
    pause_ms = Keyword.get(opts, :pause_ms, 250)
    batch = Keyword.get(opts, :batch, @batch)

    pending = Repo.aggregate(pending_query(), :count)

    summary =
      if apply?,
        do: loop(%{processed: 0, generated: 0, failed: 0}, limit, pause_ms, batch),
        else: %{processed: 0, generated: 0, failed: 0}

    result = Map.merge(summary, %{pending: pending, dry_run: not apply?})
    Logger.info("media variants backfill #{inspect(result)}")
    result
  end

  @doc "The queue: ready plain images with nothing generated yet, oldest first."
  def pending_query do
    max = Variants.max_source_bytes()

    from(a in MediaAsset,
      where:
        a.status == "ready" and is_nil(a.variants) and like(a.mime_type, "image/%") and
          a.purpose != "sealed_media" and a.size_bytes <= ^max,
      order_by: [asc: a.created_at, asc: a.id]
    )
  end

  defp loop(acc, limit, pause_ms, batch) do
    take = if is_integer(limit), do: min(batch, limit - acc.processed), else: batch

    if take <= 0 do
      acc
    else
      case Repo.all(from(a in pending_query(), limit: ^take)) do
        [] ->
          acc

        assets ->
          acc = Enum.reduce(assets, acc, &process(&1, &2))
          Logger.info("media variants backfill progress #{inspect(acc)}")
          Process.sleep(pause_ms)
          loop(acc, limit, pause_ms, batch)
      end
    end
  end

  # One asset: generate through the SAME path complete uses; a failure marks the row so it leaves
  # the queue (the live path leaves NULL so the backfill gets exactly one retry).
  defp process(%MediaAsset{} = asset, acc) do
    case Variants.generate_and_record(asset) do
      {:ok, %MediaAsset{variants: %{"thumb" => _}}} ->
        %{acc | processed: acc.processed + 1, generated: acc.generated + 1}

      {:ok, _unchanged} ->
        mark_failed(asset)
        %{acc | processed: acc.processed + 1, failed: acc.failed + 1}
    end
  end

  defp mark_failed(%MediaAsset{} = asset) do
    failed = %{
      "failed" => %{
        "reason" => "generation_failed",
        "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      }
    }

    asset
    |> MediaAsset.variants_changeset(failed, DateTime.utc_now())
    |> Repo.update()
  end
end
