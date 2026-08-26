defmodule UserService.UpiQr do
  @moduledoc """
  Server-side UPI QR PNG (100): renders the canonical `upi://pay?...` payload as a 512×512 grayscale
  PNG with a ≥4-module quiet zone, and stores it as a REGULAR user-owned media asset (purpose
  "message") through the same create-upload → PUT → complete path a client upload takes — which is
  exactly what makes the result attachable/forwardable as an ordinary image message (`/qr`).

  eqrcode supplies the matrix; the PNG is written here because eqrcode's own renderer draws the
  matrix edge-to-edge with no quiet zone, and a UPI QR without one scans unreliably off screens.
  The writer is deterministic: same payload → byte-identical PNG (locked by tests).

  The store side sits behind the `:user_service, :upi_media_writer` seam so the profile flow is
  testable without MinIO; the default writer drives the REAL media pipeline (MediaClient +
  `Req.put` of the bytes to the presigned URL — the server plays the uploading client).
  """

  require Logger

  @image_px 512
  @quiet_zone_modules 4

  @doc "Render the payload → {:ok, png_binary}. Deterministic."
  def render_png(payload) when is_binary(payload) and payload != "" do
    matrix = payload |> EQRCode.encode() |> matrix_rows()
    modules = length(matrix)
    total = modules + 2 * @quiet_zone_modules
    module_px = max(div(@image_px, total), 1)
    content_px = modules * module_px

    # Distribute the leftover pixels into the border: the quiet zone only ever GROWS past 4 modules.
    left = div(@image_px - content_px, 2)
    right = @image_px - content_px - left

    rows =
      for row <- matrix do
        pixels =
          [blank(left)] ++
            Enum.map(row, fn cell -> String.duplicate(color(cell), module_px) end) ++
            [blank(right)]

        scanline = <<0>> <> IO.iodata_to_binary(pixels)
        String.duplicate(scanline, module_px)
      end

    blank_row = String.duplicate(<<0>> <> blank(@image_px), 1)
    top = String.duplicate(blank_row, left)
    bottom = String.duplicate(blank_row, right)

    idat = :zlib.compress(IO.iodata_to_binary([top, rows, bottom]))

    {:ok,
     <<137, ?P, ?N, ?G, 13, 10, 26, 10>> <>
       chunk("IHDR", <<@image_px::32, @image_px::32, 8, 0, 0, 0, 0>>) <>
       chunk("IDAT", idat) <> chunk("IEND", "")}
  rescue
    error ->
      Logger.warning("upi qr render failed: #{inspect(error)}")
      {:error, :qr_render_failed}
  end

  def render_png(_), do: {:error, :qr_render_failed}

  @doc """
  Render + store for `user_id`/`app_id`. → {:ok, media_id} | {:error, reason}. Regeneration always
  writes a NEW asset (the profile row swaps ids; the old one is purged by the caller).
  """
  def generate_and_store(user_id, app_id, payload) do
    with {:ok, png} <- render_png(payload) do
      writer().store_png(user_id, app_id, png)
    end
  end

  @doc "Best-effort delete of a replaced/cleared QR asset — never fails the profile write."
  def purge(media_id, app_id) when is_binary(media_id) and media_id != "" do
    case SharedInfra.MediaClient.purge_asset(%{"media_id" => media_id, "app_id" => app_id}) do
      {:ok, _} -> :ok
      other -> Logger.warning("upi qr purge failed for #{media_id}: #{inspect(other)}")
    end

    :ok
  rescue
    _ -> :ok
  end

  def purge(_media_id, _app_id), do: :ok

  defp writer,
    do: Application.get_env(:user_service, :upi_media_writer, UserService.UpiQr.MediaWriter)

  defp matrix_rows(%EQRCode.Matrix{matrix: matrix}) do
    matrix
    |> Tuple.to_list()
    |> Enum.map(fn row -> row |> Tuple.to_list() end)
  end

  # 0 = black module (grayscale), 255 = white; nil cells are background.
  defp color(1), do: <<0>>
  defp color(_), do: <<255>>

  defp blank(count), do: String.duplicate(<<255>>, count)

  defp chunk(type, data) do
    payload = type <> data
    <<byte_size(data)::32>> <> payload <> <<:erlang.crc32(payload)::32>>
  end

  defmodule MediaWriter do
    @moduledoc false
    # The REAL store path: the server IS the uploading client — same rows, same authz shape, same
    # attachability as any user upload. purpose "message" (no conversation binding) so the asset can
    # ride the ordinary media-message send path.
    @callback store_png(String.t(), String.t(), binary()) ::
                {:ok, String.t()} | {:error, term()}

    def store_png(user_id, app_id, png) do
      with {:ok, upload} <-
             SharedInfra.MediaClient.create_upload(%{
               "owner_user_id" => user_id,
               "app_id" => app_id,
               "purpose" => "message",
               "filename" => "upi-qr.png",
               "content_type" => "image/png",
               "size_bytes" => byte_size(png),
               # The server IS the uploading client here: sign the PUT against the internal MinIO host
               # so the upload stays on the docker network (the public presign is browser-only, and is
               # unreachable/slow from inside the user container — the prod failure this fixes).
               "internal" => true
             }),
           media_id when is_binary(media_id) <- fetch(upload, :media_id),
           upload_url when is_binary(upload_url) <- fetch(upload, :upload_url),
           {:ok, %Req.Response{status: status}} when status in 200..299 <-
             Req.put(upload_url,
               body: png,
               headers: [{"content-type", "image/png"}],
               retry: false
             ),
           {:ok, _} <-
             SharedInfra.MediaClient.complete_upload(%{
               "media_id" => media_id,
               "app_id" => app_id
             }) do
        {:ok, media_id}
      else
        other ->
          {:error, {:qr_store_failed, other}}
      end
    end

    defp fetch(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
  end
end
