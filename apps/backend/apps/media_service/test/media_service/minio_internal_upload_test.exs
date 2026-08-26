defmodule MediaService.Storage.MinioInternalUploadTest do
  @moduledoc """
  The presign-host split for uploads (the prod UPI-QR fix). A BROWSER upload must presign against the
  public MinIO host (the SigV4 host has to match what the browser connects to). A SERVER-SIDE upload
  ("internal": true — the server acting as the media-uploading client) must presign against the
  INTERNAL host, so its PUT travels the docker network instead of the public Caddy/TLS edge that is
  unreachable/slow from inside a service container. Downloads are unaffected (still public).
  """
  use ExUnit.Case, async: false

  alias MediaService.Storage.MinioAdapter

  @internal "http://minio:9000"
  @public "https://media.growblic.com"

  setup do
    prev = Application.get_env(:media_service, :minio)

    Application.put_env(:media_service, :minio,
      endpoint: @internal,
      public_endpoint: @public,
      bucket: "chat-media",
      access_key_id: "ak",
      secret_access_key: "sk",
      region: "us-east-1",
      url_expires_seconds: 900,
      path_style: true
    )

    on_exit(fn ->
      if prev,
        do: Application.put_env(:media_service, :minio, prev),
        else: Application.delete_env(:media_service, :minio)
    end)

    :ok
  end

  defp presign(attrs) do
    {:ok, %{upload_url: url}} =
      MinioAdapter.create_upload(
        Map.merge(
          %{
            "media_id" => "m1",
            "owner_user_id" => "o1",
            "object_key" => "o1/m1/upi-qr.png",
            "expires_at" => "2026-01-01T00:00:00Z"
          },
          attrs
        )
      )

    URI.parse(url)
  end

  test "a browser upload presigns against the PUBLIC host" do
    uri = presign(%{})
    assert uri.scheme == "https"
    assert uri.host == "media.growblic.com"
  end

  test "a server-side upload (internal: true) presigns against the INTERNAL host + port" do
    uri = presign(%{"internal" => true})
    assert uri.scheme == "http"
    assert uri.host == "minio"
    assert uri.port == 9000

    # A presigned URL either way — the signature is bound to the host it embeds, so an internal URL is
    # signed for the internal host and MinIO on the docker network accepts it.
    assert uri.query =~ "X-Amz-Signature="
  end
end
