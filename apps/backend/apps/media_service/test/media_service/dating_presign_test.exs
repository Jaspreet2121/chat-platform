defmodule MediaService.DatingPresignTest do
  @moduledoc """
  The CACHEABLE presign profile — the dating deck's photos.

  Every deck fetch used to mint a fresh 900s URL for the same bytes, so a URL-keyed browser cache
  could never hit: opening the same card twice re-downloaded every photo. Two properties fix that
  and BOTH are pinned here — a window long enough to be worth caching, and a signature that is
  STABLE across requests inside one bucket (byte-identical URL, or the cache key changes and the
  long window buys nothing).

  And the clamp, which is the security half: the long window is available ONLY to an avatar asset
  whose caller asked for it by name. A message attachment, a view-once asset or a status post gets
  today's behaviour however the request is shaped.

  Offline like the other MinIO tests: presigning is pure SigV4 computation against the adapter's
  injected clock (`now:`), which is exactly what lets the bucket rounding be proven rather than
  assumed. Postgres is the only infrastructure (every create INSERTs a media_assets row).
  """
  use ExUnit.Case, async: false

  alias MediaService.Media
  alias MediaService.Repo, as: MediaRepo
  alias MediaService.Storage

  @moduletag :postgres_integration

  @owner_user_id "11111111-1111-4111-8111-111111111111"
  @app "00000000-0000-0000-0000-000000000001"

  # Two instants inside the SAME 1h bucket, and one in the next.
  @early ~U[2026-06-17 12:00:10Z]
  @late ~U[2026-06-17 12:59:50Z]
  @next_bucket ~U[2026-06-17 13:00:10Z]

  setup do
    previous_persistence = Application.get_env(:media_service, :media_persistence, false)

    previous_adapter =
      Application.get_env(:media_service, :media_storage_adapter, Storage.QueryPlanAdapter)

    previous_minio = Application.get_env(:media_service, :minio, [])

    Application.put_env(:media_service, :media_persistence, true)
    configure_minio!(@early)

    start_repo!()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MediaRepo)
    seed_owner!()

    on_exit(fn ->
      Application.put_env(:media_service, :media_persistence, previous_persistence)
      Application.put_env(:media_service, :media_storage_adapter, previous_adapter)
      Application.put_env(:media_service, :minio, previous_minio)
    end)

    :ok
  end

  # --- the pure primitive ---------------------------------------------------------------------------

  test "bucket_start floors to the bucket, and a nil bucket changes nothing" do
    assert Storage.bucket_start(@early, 3600) == ~U[2026-06-17 12:00:00Z]
    assert Storage.bucket_start(@late, 3600) == ~U[2026-06-17 12:00:00Z]
    assert Storage.bucket_start(@next_bucket, 3600) == ~U[2026-06-17 13:00:00Z]
    assert Storage.bucket_start(@early, nil) == @early
  end

  # --- the window -----------------------------------------------------------------------------------

  describe "the cacheable window" do
    test "a dating photo presigns for 2h, not the 900s default" do
      media_id = avatar!()

      params = presign_params(media_id, "cacheable")

      assert params["X-Amz-Expires"] == "7200",
             "the dating presign fell back to the default window — a URL too short to be worth " <>
               "caching (got #{params["X-Amz-Expires"]}s)"
    end

    test "the SAME asset without the profile keeps today's default" do
      media_id = avatar!()
      assert presign_params(media_id, nil)["X-Amz-Expires"] == "900"
    end

    test "expires_at is measured from the bucket start — never less than a bucket of validity left" do
      media_id = avatar!()
      {:ok, download} = download(media_id, "cacheable")

      {:ok, expires_at, _} = DateTime.from_iso8601(download.expires_at)
      remaining = DateTime.diff(expires_at, DateTime.utc_now())

      # Signed at the bucket start, so what is left is somewhere between (window - bucket) and window.
      assert remaining >= 3600,
             "a freshly-issued dating URL had only #{remaining}s left — a cached page would hold " <>
               "URLs that are already dead"

      assert remaining <= 7200
    end
  end

  # --- the stable signature -------------------------------------------------------------------------

  describe "the signature is stable within a bucket" do
    test "two presigns of the same asset inside one bucket are BYTE-IDENTICAL" do
      media_id = avatar!()

      configure_minio!(@early)
      first = url(media_id, "cacheable")

      # Nearly an hour later — same bucket, so the same URL must come back.
      configure_minio!(@late)
      second = url(media_id, "cacheable")

      assert first == second,
             "the URL changed within the bucket, so it is a fresh cache key every request and " <>
               "nothing can ever hit"
    end

    test "the NEXT bucket produces a different URL — the window does roll over" do
      media_id = avatar!()

      configure_minio!(@early)
      first = url(media_id, "cacheable")

      configure_minio!(@next_bucket)
      assert url(media_id, "cacheable") != first
    end

    test "WITHOUT the profile the signature stays per-request, exactly as before" do
      media_id = avatar!()

      configure_minio!(@early)
      first = url(media_id, nil)

      configure_minio!(@late)
      assert url(media_id, nil) != first
    end
  end

  # --- the clamp ------------------------------------------------------------------------------------

  describe "the clamp: only an avatar asset may take the long window" do
    test "a MESSAGE attachment asking for the profile gets the default window and a fresh URL" do
      media_id = message!()

      configure_minio!(@early)
      params = presign_params(media_id, "cacheable")
      first = url(media_id, "cacheable")

      assert params["X-Amz-Expires"] == "900",
             "a message attachment was widened to the dating window by asking for it"

      configure_minio!(@late)

      assert url(media_id, "cacheable") != first,
             "a message attachment's URL was made bucket-stable — it must stay per-request"
    end

    test "an unknown profile name is ignored, never treated as an opt-in" do
      media_id = avatar!()
      assert presign_params(media_id, "please")["X-Amz-Expires"] == "900"
    end
  end

  # --- helpers --------------------------------------------------------------------------------------

  defp download(media_id, url_profile) do
    attrs = %{"media_id" => media_id, "app_id" => @app}
    attrs = if url_profile, do: Map.put(attrs, "url_profile", url_profile), else: attrs
    Media.get_download_url(attrs)
  end

  defp url(media_id, url_profile) do
    {:ok, %{download_url: url}} = download(media_id, url_profile)
    url
  end

  defp presign_params(media_id, url_profile) do
    media_id |> url(url_profile) |> URI.parse() |> Map.get(:query) |> URI.decode_query()
  end

  defp avatar!, do: upload!("user_avatar")
  defp message!, do: upload!("message")

  defp upload!(purpose) do
    {:ok, upload} =
      Media.create_upload(%{
        "owner_user_id" => @owner_user_id,
        "app_id" => @app,
        "purpose" => purpose,
        "filename" => "photo.jpg",
        "content_type" => "image/jpeg",
        "size_bytes" => 400_000
      })

    upload.media_id
  end

  defp configure_minio!(now) do
    Application.put_env(:media_service, :media_storage_adapter, Storage.MinioAdapter)

    Application.put_env(:media_service, :minio,
      endpoint: "http://localhost:9000",
      public_endpoint: "https://media.growblic.com",
      bucket: "chat-media",
      access_key_id: "minioadmin",
      secret_access_key: "minioadmin",
      region: "us-east-1",
      url_expires_seconds: 900,
      path_style: true,
      now: now
    )
  end

  defp start_repo! do
    case MediaRepo.start_link() do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  defp seed_owner! do
    MediaRepo.query!(
      "INSERT INTO users_auth (id, phone_number, status) VALUES ($1::text::uuid, $2, 'active') " <>
        "ON CONFLICT DO NOTHING",
      [@owner_user_id, "+15550000001"]
    )
  end
end
