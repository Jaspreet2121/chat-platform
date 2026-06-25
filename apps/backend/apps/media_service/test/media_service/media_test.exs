defmodule MediaService.MediaTest do
  use ExUnit.Case, async: false

  alias MediaService.Media
  alias MediaService.Storage

  @owner_user_id "11111111-1111-4111-8111-111111111111"

  setup do
    previous_persistence = Application.get_env(:media_service, :media_persistence, false)

    previous_adapter =
      Application.get_env(:media_service, :media_storage_adapter, Storage.QueryPlanAdapter)

    previous_minio = Application.get_env(:media_service, :minio, [])

    Application.put_env(:media_service, :media_persistence, true)
    Application.put_env(:media_service, :media_storage_adapter, Storage.InMemoryAdapter)

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

  test "create_upload rejects unsupported content type" do
    assert {:error, :media_invalid} =
             Media.create_upload(%{
               "owner_user_id" => @owner_user_id,
               "filename" => "script.js",
               "content_type" => "application/javascript",
               "size_bytes" => 123
             })
  end

  test "create_upload accepts recorded voice audio (audio/webm)" do
    assert {:ok, upload} =
             Media.create_upload(%{
               "owner_user_id" => @owner_user_id,
               "filename" => "voice-message-123.webm",
               "content_type" => "audio/webm",
               "size_bytes" => 4096
             })

    assert is_binary(upload.upload_url)
    assert String.ends_with?(upload.object_key, "/voice-message-123.webm")
  end

  test "create_upload succeeds through safe adapter" do
    assert {:ok, upload} =
             Media.create_upload(%{
               "owner_user_id" => @owner_user_id,
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
               "object_key" => upload.object_key
             })

    assert download.media_id == upload.media_id
    assert download.download_url =~ "action=download"
    assert is_binary(download.expires_at)
  end

  test "default query-plan adapter documents live MinIO storage as unavailable" do
    Application.put_env(:media_service, :media_storage_adapter, Storage.QueryPlanAdapter)

    assert {:error, :media_storage_unavailable} =
             Media.create_upload(%{
               "owner_user_id" => @owner_user_id,
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

  test "minio adapter generates presigned download URL" do
    configure_minio_adapter!()

    object_key = "media/#{@owner_user_id}/media_123/photo.png"

    assert {:ok, download} =
             Media.get_download_url(%{
               "media_id" => "media_123",
               "owner_user_id" => @owner_user_id,
               "object_key" => object_key
             })

    uri = URI.parse(download.download_url)
    params = URI.decode_query(uri.query)

    assert uri.path == "/chat-media/#{object_key}"
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
               "filename" => "photo.png",
               "content_type" => "image/png",
               "size_bytes" => 123
             })
  end

  defp create_upload do
    Media.create_upload(%{
      "owner_user_id" => @owner_user_id,
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
end
