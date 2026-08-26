defmodule MediaService.MediaTest do
  @moduledoc """
  The media domain path with persistence ON — which since tenant-anchoring means every create INSERTs a
  media_assets row, so this suite is `@moduletag :postgres_integration` and runs in the postgres gate.
  It was previously a plain suite that predated the anchoring (no app_id, no row) and had been red ever
  since. NOT :requires_minio: the "minio adapter" tests are OFFLINE — presigning is pure SigV4
  computation against an injected frozen clock (`now:` in the adapter config); nothing here networks.
  Postgres is the only infrastructure this suite needs, and the gate provides it.
  """
  use ExUnit.Case, async: false

  alias MediaService.Media
  alias MediaService.Repo, as: MediaRepo
  alias MediaService.Storage

  @moduletag :postgres_integration

  @owner_user_id "11111111-1111-4111-8111-111111111111"
  # Tenant zero — seeded by migration 048; media_assets.app_id FKs apps(id).
  @app "00000000-0000-0000-0000-000000000001"

  # InMemoryAdapter with a believable head_object, so complete_upload's size verification can pass —
  # the same shape ApiGatewayWeb.MediaPersistencePostgresIntegrationTest uses. The verification path
  # itself (over-cap, missing PUT, fail-closed) is proven by MediaService.CompleteVerifyTest.
  defmodule SizedStorage do
    @moduledoc false
    @behaviour MediaService.Storage

    alias MediaService.Storage.InMemoryAdapter

    @impl true
    defdelegate create_upload(attrs), to: InMemoryAdapter
    @impl true
    defdelegate complete_upload(attrs), to: InMemoryAdapter
    @impl true
    defdelegate get_download_url(attrs), to: InMemoryAdapter
    @impl true
    defdelegate delete_object(attrs), to: InMemoryAdapter
    @impl true
    def head_object(_attrs), do: {:ok, %{size_bytes: 123}}
  end

  setup do
    previous_persistence = Application.get_env(:media_service, :media_persistence, false)

    previous_adapter =
      Application.get_env(:media_service, :media_storage_adapter, Storage.QueryPlanAdapter)

    previous_minio = Application.get_env(:media_service, :minio, [])

    Application.put_env(:media_service, :media_persistence, true)
    Application.put_env(:media_service, :media_storage_adapter, SizedStorage)

    start_repo!()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MediaRepo)
    seed_owner!()

    start_in_memory_storage!()
    Storage.InMemoryAdapter.reset()

    on_exit(fn ->
      Storage.InMemoryAdapter.reset()
      Application.put_env(:media_service, :media_persistence, previous_persistence)
      Application.put_env(:media_service, :media_storage_adapter, previous_adapter)
      Application.put_env(:media_service, :minio, previous_minio)
    end)

    :ok
  end

  test "create_upload validates required fields" do
    assert {:error, :media_invalid} =
             Media.create_upload(%{
               "owner_user_id" => @owner_user_id,
               "app_id" => @app,
               "filename" => "photo.png",
               "content_type" => "image/png"
             })

    assert {:error, :media_invalid} =
             Media.create_upload(%{
               "filename" => "photo.png",
               "content_type" => "image/png",
               "size_bytes" => 123
             })
  end

  # THE WHITELIST TEST — the one that would have caught the status gap and will catch the next
  # purpose someone adds. "status" was authorized downstream (presign TTL, the status authz arm)
  # months before it was uploadable: the upload whitelist was never told, every status test
  # fabricated media ids, and photo/video status 400'd in production while text status worked.
  # Rule: a purpose that exists ANYWHERE downstream must be creatable HERE, through the REAL path.
  @valid_purposes ["message", "user_avatar", "group_avatar", "status", "sealed_media"]

  test "EVERY valid purpose uploads through the real create path; an unknown one is rejected" do
    for purpose <- @valid_purposes do
      # sealed_media declares the opaque ciphertext type; every other purpose is a real image here.
      content_type =
        if purpose == "sealed_media", do: "application/octet-stream", else: "image/png"

      assert {:ok, upload} =
               Media.create_upload(%{
                 "owner_user_id" => @owner_user_id,
                 "app_id" => @app,
                 "purpose" => purpose,
                 "filename" => "asset.png",
                 "content_type" => content_type,
                 "size_bytes" => 123
               }),
             "purpose #{purpose} must be uploadable — it exists downstream (authz/presign)"

      # And the PERSISTED row carries the purpose — the value the download-side assertions gate on.
      %{rows: [[stored]]} =
        MediaRepo.query!(
          "SELECT purpose FROM media_assets WHERE id = $1::text::uuid",
          [upload.media_id]
        )

      assert stored == purpose
    end

    assert {:error, :media_invalid} =
             Media.create_upload(%{
               "owner_user_id" => @owner_user_id,
               "app_id" => @app,
               "purpose" => "not_a_purpose",
               "filename" => "asset.png",
               "content_type" => "image/png",
               "size_bytes" => 123
             })
  end

  test "create_upload rejects unsupported content type" do
    assert {:error, :media_invalid} =
             Media.create_upload(%{
               "owner_user_id" => @owner_user_id,
               "app_id" => @app,
               "filename" => "script.js",
               "content_type" => "application/javascript",
               "size_bytes" => 123
             })
  end

  test "create_upload accepts recorded voice audio (audio/webm)" do
    assert {:ok, upload} =
             Media.create_upload(%{
               "owner_user_id" => @owner_user_id,
               "app_id" => @app,
               "filename" => "voice-message-123.webm",
               "content_type" => "audio/webm",
               "size_bytes" => 4096
             })

    assert is_binary(upload.upload_url)
    assert String.ends_with?(upload.object_key, "/voice-message-123.webm")
  end

  test "create_upload accepts a codec-parameterized type (audio/webm; codecs=opus)" do
    # MediaRecorder's full type; the codecs parameter is stripped to the base before the allow-list
    # check, so this now succeeds (it was rejected as :media_invalid before the fix).
    assert {:ok, upload} =
             Media.create_upload(%{
               "owner_user_id" => @owner_user_id,
               "app_id" => @app,
               "filename" => "voice-message-123.webm",
               "content_type" => "audio/webm; codecs=opus",
               "size_bytes" => 4096
             })

    assert is_binary(upload.upload_url)
  end

  test "create_upload succeeds through safe adapter" do
    assert {:ok, upload} =
             Media.create_upload(%{
               "owner_user_id" => @owner_user_id,
               "app_id" => @app,
               "filename" => "../summer photo.png",
               "content_type" => "image/png",
               "size_bytes" => 123
             })

    assert upload.media_id =~
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

    assert upload.object_key =~ ~r(^media/#{@owner_user_id}/)
    assert String.ends_with?(upload.object_key, "/summer_photo.png")
    assert upload.upload_url =~ "action=upload"
    assert is_binary(upload.expires_at)
  end

  test "complete_upload succeeds" do
    assert {:ok, upload} = create_upload()

    assert {:ok, completed} =
             Media.complete_upload(%{
               "media_id" => upload.media_id,
               "owner_user_id" => @owner_user_id,
               "app_id" => @app,
               "object_key" => upload.object_key
             })

    assert completed.media_id == upload.media_id
    assert completed.status == "ready"
  end

  test "get_download_url succeeds" do
    assert {:ok, upload} = create_upload()

    assert {:ok, download} =
             Media.get_download_url(%{
               "media_id" => upload.media_id,
               "owner_user_id" => @owner_user_id,
               "app_id" => @app,
               "object_key" => upload.object_key
             })

    assert download.media_id == upload.media_id
    assert download.download_url =~ "action=download"
    assert is_binary(download.expires_at)
  end

  test "SEALED_MEDIA (110) is stored + served OPAQUELY: the download object_key is byte-for-byte the " <>
         "upload's, and NO derived asset is created (mutation target: any future transform hook)" do
    assert {:ok, upload} =
             Media.create_upload(%{
               "owner_user_id" => @owner_user_id,
               "app_id" => @app,
               "purpose" => "sealed_media",
               # The ciphertext's declared type — the server MUST NOT sniff or reject on it.
               "content_type" => "application/octet-stream",
               "filename" => "photo.enc",
               "size_bytes" => 4096
             })

    assert {:ok, _} =
             Media.complete_upload(%{
               "media_id" => upload.media_id,
               "owner_user_id" => @owner_user_id,
               "app_id" => @app,
               "object_key" => upload.object_key
             })

    # The download presign resolves the SAME object_key from the row — the bytes at that key are the
    # client's ciphertext, untouched (the server only presigns; it never reads or rewrites bytes).
    assert {:ok, download} =
             Media.get_download_url(%{
               "media_id" => upload.media_id,
               "app_id" => @app
             })

    # The presigned URL points at the upload's object_key (URL-encoded) — same bytes, no rewrite.
    assert download.download_url =~ URI.encode(upload.object_key)
    assert download.mime_type == "application/octet-stream"

    # OPACITY: exactly ONE media_assets row for this upload — no thumbnail / derived / sniffed row.
    # A future purpose-branched transform that spawned a derived asset would make this > 1 → red.
    %{rows: [[count]]} =
      MediaRepo.query!(
        "SELECT count(*)::int FROM media_assets WHERE object_key = $1 OR object_key LIKE $2",
        [upload.object_key, upload.object_key <> "%"]
      )

    assert count == 1
  end

  test "default query-plan adapter documents live MinIO storage as unavailable" do
    Application.put_env(:media_service, :media_storage_adapter, Storage.QueryPlanAdapter)

    assert {:error, :media_storage_unavailable} =
             Media.create_upload(%{
               "owner_user_id" => @owner_user_id,
               "app_id" => @app,
               "filename" => "photo.png",
               "content_type" => "image/png",
               "size_bytes" => 123
             })
  end

  test "minio adapter generates presigned upload URL" do
    configure_minio_adapter!()

    assert {:ok, upload} =
             Media.create_upload(%{
               "owner_user_id" => @owner_user_id,
               "app_id" => @app,
               "filename" => "summer photo.png",
               "content_type" => "image/png",
               "size_bytes" => 123
             })

    uri = URI.parse(upload.upload_url)
    params = URI.decode_query(uri.query)

    assert uri.scheme == "http"
    assert uri.host == "localhost"
    assert uri.port == 9000
    assert uri.path == "/chat-media/#{upload.object_key |> String.replace(" ", "%20")}"
    assert params["X-Amz-Algorithm"] == "AWS4-HMAC-SHA256"
    assert params["X-Amz-Credential"] =~ "minioadmin/20260617/us-east-1/s3/aws4_request"
    assert params["X-Amz-Date"] == "20260617T120000Z"
    assert params["X-Amz-Expires"] == "900"
    assert params["X-Amz-SignedHeaders"] == "host"
    assert params["X-Amz-Content-Sha256"] == "UNSIGNED-PAYLOAD"
    assert params["X-Amz-Signature"] =~ ~r/^[0-9a-f]{64}$/
  end

  test "minio adapter SigV4 canonical host omits scheme-default ports, keeps explicit ones" do
    # The signed host must match the Host header the client actually sends: browsers omit :443/:80.
    assert Storage.MinioAdapter.canonical_host(URI.parse("https://media.growblic.com")) ==
             "media.growblic.com"

    assert Storage.MinioAdapter.canonical_host(URI.parse("https://media.growblic.com:443")) ==
             "media.growblic.com"

    assert Storage.MinioAdapter.canonical_host(URI.parse("http://media.growblic.com")) ==
             "media.growblic.com"

    # Non-default ports stay — internal signing against http://minio:9000 must keep ":9000".
    assert Storage.MinioAdapter.canonical_host(URI.parse("http://minio:9000")) == "minio:9000"

    assert Storage.MinioAdapter.canonical_host(URI.parse("http://localhost:9000")) ==
             "localhost:9000"

    assert Storage.MinioAdapter.canonical_host(URI.parse("https://media.growblic.com:8443")) ==
             "media.growblic.com:8443"
  end

  test "minio adapter presigned URL over https public endpoint carries no default port" do
    configure_minio_adapter!()

    minio = Application.get_env(:media_service, :minio, [])

    Application.put_env(
      :media_service,
      :minio,
      Keyword.put(minio, :public_endpoint, "https://media.growblic.com")
    )

    assert {:ok, upload} =
             Media.create_upload(%{
               "owner_user_id" => @owner_user_id,
               "app_id" => @app,
               "filename" => "photo.png",
               "content_type" => "image/png",
               "size_bytes" => 123
             })

    refute upload.upload_url =~ ":443"
    uri = URI.parse(upload.upload_url)
    assert uri.scheme == "https"
    assert uri.host == "media.growblic.com"
    assert URI.decode_query(uri.query)["X-Amz-Signature"] =~ ~r/^[0-9a-f]{64}$/
  end

  test "minio adapter generates presigned download URL FROM THE ROW (client object_key ignored)" do
    configure_minio_adapter!()

    # The row must exist: downloads resolve the object_key server-side since the capability fix — a
    # client-supplied key is never presigned. So create first (INSERTs the row), then download by id.
    assert {:ok, upload} =
             Media.create_upload(%{
               "owner_user_id" => @owner_user_id,
               "app_id" => @app,
               "filename" => "photo.png",
               "content_type" => "image/png",
               "size_bytes" => 123
             })

    assert {:ok, download} =
             Media.get_download_url(%{
               "media_id" => upload.media_id,
               "owner_user_id" => @owner_user_id,
               "app_id" => @app,
               # POISONED client key — must be ignored in favour of the row's.
               "object_key" => "media/#{@owner_user_id}/somewhere/else.png"
             })

    uri = URI.parse(download.download_url)
    params = URI.decode_query(uri.query)

    # The presigned path is the ROW's server-generated key, not the poisoned one.
    assert uri.path == "/chat-media/#{upload.object_key}"
    refute uri.path =~ "somewhere/else"
    assert params["X-Amz-Algorithm"] == "AWS4-HMAC-SHA256"
    assert params["X-Amz-Credential"] =~ "minioadmin/20260617/us-east-1/s3/aws4_request"
    assert params["X-Amz-Signature"] =~ ~r/^[0-9a-f]{64}$/
  end

  test "minio adapter returns safe error when required config is missing" do
    Application.put_env(:media_service, :media_storage_adapter, Storage.MinioAdapter)

    Application.put_env(:media_service, :minio,
      endpoint: "http://localhost:9000",
      bucket: "chat-media",
      access_key_id: "",
      secret_access_key: "minioadmin",
      region: "us-east-1"
    )

    assert {:error, :media_storage_unavailable} =
             Media.create_upload(%{
               "owner_user_id" => @owner_user_id,
               "app_id" => @app,
               "filename" => "photo.png",
               "content_type" => "image/png",
               "size_bytes" => 123
             })
  end

  defp create_upload do
    Media.create_upload(%{
      "owner_user_id" => @owner_user_id,
      "app_id" => @app,
      "filename" => "photo.png",
      "content_type" => "image/png",
      "size_bytes" => 123
    })
  end

  defp configure_minio_adapter! do
    Application.put_env(:media_service, :media_storage_adapter, Storage.MinioAdapter)

    Application.put_env(:media_service, :minio,
      endpoint: "http://localhost:9000",
      bucket: "chat-media",
      access_key_id: "minioadmin",
      secret_access_key: "minioadmin",
      region: "us-east-1",
      url_expires_seconds: 900,
      path_style: true,
      now: ~U[2026-06-17 12:00:00Z]
    )
  end

  defp start_in_memory_storage! do
    case Storage.InMemoryAdapter.start_link() do
      {:ok, pid} ->
        Process.unlink(pid)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end

  defp start_repo! do
    case MediaRepo.start_link() do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # media_assets.owner_user_id FKs users_auth(id) — the row must exist before any INSERTing create.
  defp seed_owner! do
    MediaRepo.query!(
      "INSERT INTO users_auth (id, phone_number, status) VALUES ($1::text::uuid, $2, 'active') " <>
        "ON CONFLICT DO NOTHING",
      [@owner_user_id, "+15550000001"]
    )
  end
end
