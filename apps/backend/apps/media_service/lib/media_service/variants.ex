defmodule MediaService.Variants do
  @moduledoc """
  Server-side image variants (124): for a PLAIN image asset, a `thumb` (256 px long edge, JPEG q70)
  and a `medium` (1280 px long edge, JPEG q80), EXIF stripped, auto-rotated, stored beside the
  original as `<object_key>.thumb.jpg` / `<object_key>.medium.jpg`, recorded in
  `media_assets.variants`.

  ## When

  Synchronously on the upload's complete (`MediaService.Media` → `mark_ready/2`), so the message that
  attaches the asset a moment later already carries `thumb_url`. Measured on the worst case that
  matters (an 8.8 MB 4000×3000 JPEG): thumb ≈ 70 ms, medium ≈ 100 ms on one laptop core — a few
  hundred ms on the 2-vCPU box. The work runs in a linked task with a hard deadline, so a
  pathological source (a decompression bomb, a 20 000 px SVG) cannot pin the request.

  ## Never

    * SEALED assets (`purpose == "sealed_media"`): the bytes are ciphertext. Refused by purpose
      BEFORE anything is read — a sealed asset carrying an image mime is still refused.
    * Anything not `image/*`, anything over #{div(25 * 1024 * 1024, 1024 * 1024)} MB (the claim at
      create AND the measured size at complete), anything already generated.

  ## Failure

  A derivative must never fail the original: every outcome of `generate_and_record/1` is
  `{:ok, asset}` — the asset with variants recorded, or exactly the asset that was passed in,
  logged. No exception escapes. Sources libvips cannot decode (HEIC from an iPhone: the bundled
  libvips has no HEVC decoder) land here too — logged, no variants, the client shows the original.
  """

  require Logger

  alias MediaService.Repo
  alias MediaService.Schemas.MediaAsset
  alias MediaService.Storage
  alias Vix.Vips.{Image, Operation}

  @max_source_bytes 25 * 1024 * 1024
  # name → {long edge px, JPEG quality}
  @specs [thumb: {256, 70}, medium: {1280, 80}]
  @timeout_ms 20_000

  @doc "Largest source we will read and render, in bytes."
  def max_source_bytes, do: @max_source_bytes

  @doc "The variant names in generation order."
  def names, do: Keyword.keys(@specs) |> Enum.map(&Atom.to_string/1)

  @doc """
  Is this asset one we generate for? READY, plain (never sealed), `image/*`, within the size cap,
  nothing generated yet.
  """
  def eligible?(%MediaAsset{} = asset) do
    asset.status == "ready" and asset.purpose != "sealed_media" and image?(asset.mime_type) and
      is_integer(asset.size_bytes) and asset.size_bytes <= @max_source_bytes and
      is_nil(asset.variants)
  end

  def eligible?(_other), do: false

  defp image?(mime_type) when is_binary(mime_type), do: String.starts_with?(mime_type, "image/")
  defp image?(_other), do: false

  @doc """
  Generate, store and record the variants of one READY asset. ALWAYS `{:ok, asset}` — with the
  variants recorded on success, untouched on skip or failure (logged). Never raises.
  """
  def generate_and_record(%MediaAsset{} = asset) do
    if eligible?(asset) do
      started = System.monotonic_time(:millisecond)

      case generate(asset) do
        {:ok, variants} ->
          case record(asset, variants) do
            {:ok, updated} ->
              Logger.info(
                "media variants generated media_id=#{asset.id} " <>
                  "thumb=#{variants["thumb"]["bytes"]}b medium=#{variants["medium"]["bytes"]}b " <>
                  "ms=#{System.monotonic_time(:millisecond) - started}"
              )

              {:ok, updated}

            {:error, reason} ->
              log_failure(asset, reason, started)
              {:ok, asset}
          end

        {:error, reason} ->
          log_failure(asset, reason, started)
          {:ok, asset}
      end
    else
      {:ok, asset}
    end
  rescue
    error ->
      Logger.warning("media variants failed media_id=#{asset.id} reason=#{inspect(error)}")
      {:ok, asset}
  end

  @doc """
  Render + store the variants for an asset (no DB write) → `{:ok, variants_map} | {:error, reason}`.
  Runs the read/render/write in a linked task under a #{@timeout_ms} ms deadline. Never raises.
  """
  def generate(%MediaAsset{} = asset) do
    if Storage.objects_supported?() do
      bounded(fn -> render_and_store(asset) end)
    else
      {:error, :objects_unsupported}
    end
  end

  # The task function catches EVERYTHING itself: a linked task that crashed would take the caller
  # (the complete request) down with it before `Task.yield` could report the exit.
  defp bounded(fun) do
    task =
      Task.async(fn ->
        try do
          fun.()
        rescue
          error -> {:error, error}
        catch
          kind, value -> {:error, {kind, value}}
        end
      end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:exit, reason}}
      nil -> {:error, :timeout}
    end
  end

  defp render_and_store(%MediaAsset{} = asset) do
    with {:ok, source} <- fetch_source(asset) do
      Enum.reduce_while(@specs, {:ok, %{}}, fn {name, {edge, quality}}, {:ok, acc} ->
        key = variant_key(asset.object_key, name)

        with {:ok, rendered} <- render(source, edge, quality),
             :ok <-
               Storage.put_object(%{
                 "object_key" => key,
                 "body" => rendered.bytes,
                 "content_type" => "image/jpeg"
               }) do
          {:cont,
           {:ok,
            Map.put(acc, Atom.to_string(name), %{
              "key" => key,
              "w" => rendered.w,
              "h" => rendered.h,
              "bytes" => byte_size(rendered.bytes)
            })}}
        else
          {:error, reason} -> {:halt, {:error, {name, reason}}}
        end
      end)
    end
  end

  defp fetch_source(%MediaAsset{object_key: object_key}) do
    case Storage.get_object(%{"object_key" => object_key}) do
      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= @max_source_bytes -> {:ok, bytes}
      {:ok, bytes} when is_binary(bytes) -> {:error, :source_too_large}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected, other}}
    end
  end

  # Shrink-on-load into an edge×edge box (never upscaled), honouring the EXIF orientation, alpha
  # flattened onto white, then a baseline JPEG with EVERY metadata block stripped — no EXIF, no GPS,
  # no ICC, no XMP leaves the server in a derivative.
  defp render(source, edge, quality) do
    with {:ok, image} <-
           Operation.thumbnail_buffer(source, edge, height: edge, size: :VIPS_SIZE_DOWN),
         {:ok, image} <- flatten(image),
         {:ok, bytes} <-
           Image.write_to_buffer(image, ".jpg[Q=#{quality},strip=true,optimize_coding=true]") do
      {:ok, %{bytes: bytes, w: Image.width(image), h: Image.height(image)}}
    end
  end

  defp flatten(image) do
    if Image.has_alpha?(image),
      do: Operation.flatten(image, background: [255.0, 255.0, 255.0]),
      else: {:ok, image}
  end

  @doc "The object key of a variant: `<object_key>.<name>.jpg`."
  def variant_key(object_key, name), do: "#{object_key}.#{name}.jpg"

  defp record(%MediaAsset{} = asset, variants) do
    asset
    |> MediaAsset.variants_changeset(variants, DateTime.utc_now())
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, changeset} -> {:error, {:record, changeset.errors}}
    end
  end

  defp log_failure(asset, reason, started) do
    Logger.warning(
      "media variants failed media_id=#{asset.id} mime=#{asset.mime_type} " <>
        "size=#{asset.size_bytes} reason=#{inspect(reason)} " <>
        "ms=#{System.monotonic_time(:millisecond) - started}"
    )
  end
end
