defmodule MediaService.VariantsTest do
  @moduledoc """
  Server-side image variants (124) on the REAL complete path, real libvips, real rows
  (`@moduletag :postgres_integration`), in-memory object store with a read counter.

  Proves: complete generates thumb (256 long edge, q70) + medium (1280, q80) beside the original,
  EXIF stripped and orientation applied, recorded in `variants`, logged — and the complete response
  is byte-for-byte what it was. A SEALED asset is never read, even with an image mime planted on
  it (MUT-5). EXIF never survives into a derivative (MUT-6). A failed generation never fails the
  upload (MUT-7). Over-cap and non-image sources are skipped without a read. The backfill drains
  the pre-124 queue in batches, marks a broken source once, and never sees a sealed row.
  """
  use ExUnit.Case, async: false

  @moduletag :postgres_integration

  import ExUnit.CaptureLog

  alias MediaService.Media
  alias MediaService.Repo, as: MediaRepo
  alias MediaService.Schemas.MediaAsset
  alias MediaService.Storage
  alias MediaService.Variants
  alias MediaService.Variants.Backfill
  alias Vix.Vips.{Image, MutableImage, Operation}

  @owner "11111111-1111-4111-8111-111111111111"
  @app "00000000-0000-0000-0000-000000000001"

  # InMemoryAdapter + a believable HEAD (the stored object's size, or an override for a source we
  # deliberately never store) + a counter of ORIGINAL reads — the sealed proof is "zero reads".
  defmodule CountingStorage do
    @moduledoc false
    @behaviour MediaService.Storage
    @counter __MODULE__.Counter

    def start do
      case Agent.start(fn -> %{reads: 0, head_override: nil} end, name: @counter) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      Agent.update(@counter, fn _ -> %{reads: 0, head_override: nil} end)
    end

    def reads, do: Agent.get(@counter, & &1.reads)
    def set_head_override(size), do: Agent.update(@counter, &Map.put(&1, :head_override, size))

    @impl true
    defdelegate create_upload(attrs), to: Storage.InMemoryAdapter
    @impl true
    defdelegate complete_upload(attrs), to: Storage.InMemoryAdapter
    @impl true
    defdelegate get_download_url(attrs), to: Storage.InMemoryAdapter
    @impl true
    defdelegate delete_object(attrs), to: Storage.InMemoryAdapter
    @impl true
    defdelegate put_object(attrs), to: Storage.InMemoryAdapter

    @impl true
    def get_object(attrs) do
      Agent.update(@counter, &Map.update!(&1, :reads, fn n -> n + 1 end))
      Storage.InMemoryAdapter.get_object(attrs)
    end

    @impl true
    def head_object(%{"object_key" => key}) do
      case {Storage.InMemoryAdapter.object(key), Agent.get(@counter, & &1.head_override)} do
        {%{body: body}, _} -> {:ok, %{object_key: key, size_bytes: byte_size(body)}}
        {nil, size} when is_integer(size) -> {:ok, %{object_key: key, size_bytes: size}}
        _ -> {:error, :upload_not_found}
      end
    end
  end

  setup do
    prev = %{
      persistence: Application.get_env(:media_service, :media_persistence, false),
      adapter:
        Application.get_env(:media_service, :media_storage_adapter, Storage.QueryPlanAdapter)
    }

    Application.put_env(:media_service, :media_persistence, true)
    Application.put_env(:media_service, :media_storage_adapter, CountingStorage)

    case MediaRepo.start_link() do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MediaRepo)

    # The generator renders in a linked Task; the DB write happens in the caller. Shared mode keeps
    # the (rare) case where a test helper reads from another process working.
    Ecto.Adapters.SQL.Sandbox.mode(MediaRepo, {:shared, self()})

    MediaRepo.query!(
      "INSERT INTO users_auth (id, phone_number, status) VALUES ($1::text::uuid, $2, 'active') " <>
        "ON CONFLICT DO NOTHING",
      [@owner, "+15550000001"]
    )

    case Storage.InMemoryAdapter.start_link() do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end

    Storage.InMemoryAdapter.reset()
    CountingStorage.start()

    on_exit(fn ->
      Storage.InMemoryAdapter.reset()
      Application.put_env(:media_service, :media_persistence, prev.persistence)
      Application.put_env(:media_service, :media_storage_adapter, prev.adapter)
    end)

    :ok
  end

  # A real JPEG with EXIF (camera make/model) and, optionally, an EXIF orientation tag.
  defp jpeg(width, height, opts \\ []) do
    {:ok, img} = Operation.black(width, height, bands: 3)
    {:ok, img} = Operation.linear(img, [1.0, 1.0, 1.0], [40.0, 90.0, 160.0])
    {:ok, img} = Operation.cast(img, :VIPS_FORMAT_UCHAR)

    {:ok, img} =
      Image.mutate(img, fn m ->
        :ok = MutableImage.set(m, "exif-ifd0-Make", :gchararray, "TestCam")
        :ok = MutableImage.set(m, "exif-ifd0-Model", :gchararray, "X1")

        if opts[:orientation],
          do: :ok = MutableImage.set(m, "orientation", :gint, opts[:orientation])

        :ok
      end)

    {:ok, bytes} = Image.write_to_buffer(img, ".jpg[Q=90]")
    bytes
  end

  defp exif_fields(bytes) do
    {:ok, img} = Image.new_from_buffer(bytes)
    {:ok, names} = Image.header_field_names(img)
    Enum.filter(names, &(String.starts_with?(&1, "exif-") or &1 == "orientation"))
  end

  defp dims(bytes) do
    {:ok, img} = Image.new_from_buffer(bytes)
    {Image.width(img), Image.height(img)}
  end

  defp upload!(content_type, filename, size, extra \\ %{}) do
    {:ok, upload} =
      Media.create_upload(
        Map.merge(
          %{
            "owner_user_id" => @owner,
            "app_id" => @app,
            "filename" => filename,
            "content_type" => content_type,
            "size_bytes" => size
          },
          extra
        )
      )

    upload
  end

  defp store!(upload, bytes, content_type) do
    :ok =
      Storage.InMemoryAdapter.put_object(%{
        "object_key" => upload.object_key,
        "body" => bytes,
        "content_type" => content_type
      })
  end

  defp complete!(upload) do
    Media.complete_upload(%{
      "media_id" => upload.media_id,
      "owner_user_id" => @owner,
      "app_id" => @app
    })
  end

  defp asset!(media_id), do: MediaRepo.get!(MediaAsset, media_id)

  defp conversation! do
    id = Ecto.UUID.generate()

    MediaRepo.query!(
      "INSERT INTO conversations (id, type, created_by, app_id) " <>
        "VALUES ($1::text::uuid, 'direct', $2::text::uuid, $3::text::uuid)",
      [id, @owner, @app]
    )

    id
  end

  test "COMPLETE generates thumb + medium beside the original, auto-rotated, recorded, logged; complete response unchanged" do
    source = jpeg(1600, 1200, orientation: 6)
    assert length(exif_fields(source)) >= 2
    upload = upload!("image/jpeg", "photo.jpg", byte_size(source))
    store!(upload, source, "image/jpeg")

    log =
      capture_log([level: :info], fn ->
        assert {:ok, response} = complete!(upload)
        # KEY-SET: the complete ack is exactly what it was before variants existed.
        assert response == %{media_id: upload.media_id, status: "ready"}
      end)

    asset = asset!(upload.media_id)
    assert asset.status == "ready"
    assert Map.keys(asset.variants) |> Enum.sort() == ["medium", "thumb"]

    thumb = asset.variants["thumb"]
    medium = asset.variants["medium"]
    assert Map.keys(thumb) |> Enum.sort() == ["bytes", "h", "key", "w"]
    assert thumb["key"] == "#{upload.object_key}.thumb.jpg"
    assert medium["key"] == "#{upload.object_key}.medium.jpg"

    # Orientation 6 = rotate 90°: the 1600×1200 source renders PORTRAIT, long edge = the spec.
    assert {thumb["w"], thumb["h"]} == {192, 256}
    assert {medium["w"], medium["h"]} == {960, 1280}

    for {name, meta} <- [{"thumb", thumb}, {"medium", medium}] do
      stored = Storage.InMemoryAdapter.object(meta["key"])
      assert %{body: body, content_type: "image/jpeg"} = stored
      assert byte_size(body) == meta["bytes"]
      assert meta["bytes"] > 0
      assert dims(body) == {meta["w"], meta["h"]}
      assert exif_fields(body) == [], "#{name} still carries metadata"
    end

    assert CountingStorage.reads() == 1

    assert log =~
             ~r/media variants generated media_id=#{upload.media_id} thumb=\d+b medium=\d+b ms=\d+/
  end

  test "MUT-6: EXIF (make/model/orientation) never survives into a derivative" do
    source = jpeg(800, 600)
    upload = upload!("image/jpeg", "exif.jpg", byte_size(source))
    store!(upload, source, "image/jpeg")
    assert {:ok, _} = complete!(upload)

    for name <- Variants.names() do
      %{body: body} =
        Storage.InMemoryAdapter.object(Variants.variant_key(upload.object_key, name))

      assert exif_fields(body) == []
    end
  end

  test "MUT-5: a SEALED asset is never read — not even with an image mime planted on the row" do
    conversation_id = conversation!()
    ciphertext = :crypto.strong_rand_bytes(4096)

    upload =
      upload!("application/octet-stream", "blob.bin", byte_size(ciphertext), %{
        "purpose" => "sealed_media",
        "conversation_id" => conversation_id
      })

    store!(upload, ciphertext, "application/octet-stream")

    # Plant the one thing a mime-only guard would fall for.
    asset!(upload.media_id)
    |> Ecto.Changeset.change(mime_type: "image/jpeg")
    |> MediaRepo.update!()

    assert {:ok, %{status: "ready"}} = complete!(upload)

    asset = asset!(upload.media_id)
    assert asset.purpose == "sealed_media"
    assert asset.status == "ready"
    assert asset.variants == nil
    assert CountingStorage.reads() == 0
    assert Storage.InMemoryAdapter.object("#{upload.object_key}.thumb.jpg") == nil
  end

  test "MUT-7: a source libvips cannot decode → upload completes ready, no variants, one warning" do
    garbage = :crypto.strong_rand_bytes(2048)
    upload = upload!("image/png", "broken.png", byte_size(garbage))
    store!(upload, garbage, "image/png")

    log =
      capture_log([level: :warning], fn ->
        assert {:ok, %{media_id: _, status: "ready"}} = complete!(upload)
      end)

    asset = asset!(upload.media_id)
    assert asset.status == "ready"
    assert asset.variants == nil
    assert log =~ "media variants failed media_id=#{upload.media_id}"
    assert Storage.InMemoryAdapter.object("#{upload.object_key}.thumb.jpg") == nil
  end

  test "a source over 25 MB, and a non-image, are skipped WITHOUT a read" do
    big = upload!("image/jpeg", "huge.jpg", 26 * 1024 * 1024)
    CountingStorage.set_head_override(26 * 1024 * 1024)
    assert {:ok, %{status: "ready"}} = complete!(big)
    assert asset!(big.media_id).variants == nil

    CountingStorage.set_head_override(nil)
    video = upload!("video/mp4", "clip.mp4", 10)
    store!(video, "not really a video", "video/mp4")
    assert {:ok, %{status: "ready"}} = complete!(video)
    assert asset!(video.media_id).variants == nil

    assert CountingStorage.reads() == 0
  end

  describe "backfill" do
    # A READY image with NO variants — the pre-124 shape — by completing and then clearing.
    defp pre_124_image!(filename, bytes) do
      upload = upload!("image/jpeg", filename, byte_size(bytes))
      store!(upload, bytes, "image/jpeg")
      assert {:ok, _} = complete!(upload)

      asset!(upload.media_id)
      |> MediaAsset.variants_changeset(nil, DateTime.utc_now())
      |> MediaRepo.update!()

      upload
    end

    test "dry run counts, apply drains in batches with a limit, a broken source is marked ONCE, sealed never queued" do
      good = for i <- 1..3, do: pre_124_image!("old#{i}.jpg", jpeg(640, 480))
      broken = pre_124_image!("broken.jpg", jpeg(64, 48))

      :ok =
        Storage.InMemoryAdapter.put_object(%{
          "object_key" => broken.object_key,
          "body" => :crypto.strong_rand_bytes(512),
          "content_type" => "image/jpeg"
        })

      conversation_id = conversation!()

      sealed =
        upload!("application/octet-stream", "blob.bin", 16, %{
          "purpose" => "sealed_media",
          "conversation_id" => conversation_id
        })

      store!(sealed, :crypto.strong_rand_bytes(16), "application/octet-stream")
      assert {:ok, _} = complete!(sealed)

      CountingStorage.start()

      # Dry run: the queue is the 4 plain images; nothing is touched.
      assert %{pending: 4, processed: 0, generated: 0, failed: 0, dry_run: true} = Backfill.run()
      assert CountingStorage.reads() == 0

      # Two batches of one, capped at 2: resumable — the next run picks up the rest.
      assert %{processed: 2, generated: 2, failed: 0, dry_run: false} =
               Backfill.run(apply: true, limit: 2, batch: 1, pause_ms: 0)

      assert %{pending: 2} = Backfill.run()

      log =
        capture_log([level: :warning], fn ->
          assert %{processed: 2, generated: 1, failed: 1} = Backfill.run(apply: true, pause_ms: 0)
        end)

      assert log =~ "media variants failed media_id=#{broken.media_id}"

      for upload <- good do
        assert %{"thumb" => %{"key" => key}} = asset!(upload.media_id).variants
        assert key == "#{upload.object_key}.thumb.jpg"
        assert %{body: _} = Storage.InMemoryAdapter.object(key)
      end

      # The broken one left the queue, marked — attempted once, never again.
      assert %{"failed" => %{"reason" => "generation_failed", "at" => _}} =
               asset!(broken.media_id).variants

      assert %{pending: 0} = Backfill.run()
      assert asset!(sealed.media_id).variants == nil
    end
  end
end
