defmodule MediaService.DownloadUrlsTest do
  @moduledoc """
  The BATCHED presign behind the inline timeline link (`MessageService.MediaLinks`):
  `Media.get_download_urls/1` answers one row per asset that exists in the caller's app, each row
  presigned for THAT asset's object_key with the SAME bounded TTL the single read mints (15 minutes,
  shorten-only). Tenant-foreign, unknown and malformed ids are absent — never presigned, never a
  failure. Timing: 20 real SigV4 signatures + one query, measured, must stay well under the 30 ms
  budget the timeline page was given.
  """
  use ExUnit.Case, async: false

  @moduletag :postgres_integration

  alias MediaService.Media
  alias MediaService.Repo, as: MediaRepo
  alias MediaService.Storage

  @owner "11111111-1111-4111-8111-111111111111"
  # Tenant zero — seeded by migration 048; media_assets.app_id FKs apps(id).
  @app "00000000-0000-0000-0000-000000000001"
  @other_app "00000000-0000-0000-0000-000000000002"

  setup do
    prev = %{
      persistence: Application.get_env(:media_service, :media_persistence, false),
      adapter:
        Application.get_env(:media_service, :media_storage_adapter, Storage.QueryPlanAdapter),
      minio: Application.get_env(:media_service, :minio, [])
    }

    Application.put_env(:media_service, :media_persistence, true)
    # REAL SigV4 signing (pure computation — no MinIO is contacted), so the URL carries the real
    # X-Amz-Expires and the real object path. A frozen clock keeps the credential scope stable.
    Application.put_env(:media_service, :media_storage_adapter, Storage.MinioAdapter)

    Application.put_env(:media_service, :minio,
      endpoint: "http://localhost:9000",
      bucket: "chat-media",
      access_key_id: "minioadmin",
      secret_access_key: "minioadmin",
      region: "us-east-1",
      url_expires_seconds: 900,
      path_style: true
    )

    case MediaRepo.start_link() do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MediaRepo)

    MediaRepo.query!(
      "INSERT INTO users_auth (id, phone_number, status) VALUES ($1::text::uuid, $2, 'active') " <>
        "ON CONFLICT DO NOTHING",
      [@owner, "+15550000001"]
    )

    MediaRepo.query!(
      "INSERT INTO apps (id, name, slug) VALUES ($1::text::uuid, 'other', 'other-dl') ON CONFLICT DO NOTHING",
      [@other_app]
    )

    on_exit(fn ->
      Application.put_env(:media_service, :media_persistence, prev.persistence)
      Application.put_env(:media_service, :media_storage_adapter, prev.adapter)
      Application.put_env(:media_service, :minio, prev.minio)
    end)

    :ok
  end

  defp upload!(app \\ @app, filename \\ "photo.png") do
    {:ok, upload} =
      Media.create_upload(%{
        "owner_user_id" => @owner,
        "app_id" => app,
        "filename" => filename,
        "content_type" => "image/png",
        "size_bytes" => 123
      })

    upload
  end

  defp batch(ids, app \\ @app, extra \\ %{}) do
    Media.get_download_urls(
      Map.merge(%{"media_ids" => ids, "app_id" => app, "url_expires_seconds" => 900}, extra)
    )
  end

  test "one row per asset, each presigned for ITS OWN object_key, with the bounded 15-minute TTL" do
    a = upload!(@app, "a.png")
    b = upload!(@app, "b.png")
    before = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, %{downloads: downloads}} = batch([a.media_id, b.media_id])
    assert length(downloads) == 2

    by_id = Map.new(downloads, &{&1.media_id, &1})

    for upload <- [a, b] do
      row = Map.fetch!(by_id, upload.media_id)
      # KEY-SET: the batch row is byte-for-byte the single read's shape.
      assert Map.keys(row) |> Enum.sort() == [:download_url, :expires_at, :media_id, :mime_type]
      assert row.mime_type == "image/png"

      uri = URI.parse(row.download_url)
      params = URI.decode_query(uri.query)
      # MUT-3 guard: the URL is for THIS message's object, not its neighbour's.
      assert uri.path == "/chat-media/#{upload.object_key}"
      assert params["X-Amz-Algorithm"] == "AWS4-HMAC-SHA256"
      # MUT-2 guard: the signature itself is bounded to the requested 900 s ...
      assert params["X-Amz-Expires"] == "900"
      # ... and the advertised expiry is at most 15 minutes out (never absent, never unbounded).
      {:ok, expires_at, 0} = DateTime.from_iso8601(row.expires_at)
      assert DateTime.compare(expires_at, before) == :gt
      assert DateTime.diff(expires_at, before, :second) <= 900
    end

    # Distinct objects → distinct URLs.
    assert by_id[a.media_id].download_url != by_id[b.media_id].download_url
  end

  test "a longer TTL cannot be bought by asking: url_expires_seconds is shorten-only" do
    a = upload!()
    before = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, %{downloads: [row]}} =
             batch([a.media_id], @app, %{"url_expires_seconds" => 86_400})

    {:ok, expires_at, 0} = DateTime.from_iso8601(row.expires_at)
    assert DateTime.diff(expires_at, before, :second) <= 900
    assert URI.decode_query(URI.parse(row.download_url).query)["X-Amz-Expires"] == "900"
  end

  test "tenant-foreign, unknown and malformed ids are ABSENT, never presigned, never a failure" do
    mine = upload!(@app)
    theirs = upload!(@other_app)

    assert {:ok, %{downloads: downloads}} =
             batch([mine.media_id, theirs.media_id, Ecto.UUID.generate(), "not-a-uuid", ""])

    assert Enum.map(downloads, & &1.media_id) == [mine.media_id]
  end

  test "the purpose filter applies to the batch exactly as to the single read" do
    a = upload!()
    assert {:ok, %{downloads: []}} = batch([a.media_id], @app, %{"purpose" => "user_avatar"})
    assert {:ok, %{downloads: [_]}} = batch([a.media_id], @app, %{"purpose" => "message"})
  end

  test "input validation: media_ids must be a list of at most 100; app_id required" do
    assert {:error, :media_invalid} = Media.get_download_urls(%{"app_id" => @app})

    assert {:error, :media_invalid} =
             Media.get_download_urls(%{"media_ids" => "x", "app_id" => @app})

    assert {:error, :media_invalid} = Media.get_download_urls(%{"media_ids" => []})

    too_many = for _ <- 1..101, do: Ecto.UUID.generate()
    assert {:error, :media_invalid} = batch(too_many)
    assert {:ok, %{downloads: []}} = batch([])
  end

  test "TIMING: 20 media on one page — one query + 20 SigV4 signatures, measured" do
    uploads = for i <- 1..20, do: upload!(@app, "p#{i}.png")
    ids = Enum.map(uploads, & &1.media_id)
    # Warm the code path once so the measurement is the steady state.
    assert {:ok, %{downloads: warm}} = batch(ids)
    assert length(warm) == 20

    {micros, {:ok, %{downloads: downloads}}} = :timer.tc(fn -> batch(ids) end)
    assert length(downloads) == 20

    IO.puts(
      "\n[download_urls timing] 20 assets: #{Float.round(micros / 1000, 2)} ms (query + 20 presigns, in-process)"
    )

    # The page budget is 30 ms; the in-process cost must leave room for the internal HTTP hop.
    assert micros < 30_000
  end
end
