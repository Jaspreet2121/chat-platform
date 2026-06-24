defmodule MediaService.Storage do
  @moduledoc """
  Adapter boundary for media object storage.

  The default adapter is intentionally non-networked. Configure an adapter
  explicitly before attempting live MinIO/S3 operations.
  """

  @type attrs :: map()
  @type result :: {:ok, map()} | {:error, atom()}

  @callback create_upload(attrs()) :: result()
  @callback complete_upload(attrs()) :: result()
  @callback get_download_url(attrs()) :: result()

  def create_upload(attrs), do: adapter().create_upload(attrs)
  def complete_upload(attrs), do: adapter().complete_upload(attrs)
  def get_download_url(attrs), do: adapter().get_download_url(attrs)

  defp adapter do
    Application.get_env(
      :media_service,
      :media_storage_adapter,
      MediaService.Storage.QueryPlanAdapter
    )
  end
end

defmodule MediaService.Storage.QueryPlanAdapter do
  @moduledoc """
  Non-networked storage placeholder.

  This keeps DB-backed service code honest when no live MinIO/S3 client is
  configured.
  """

  @behaviour MediaService.Storage

  @impl true
  def create_upload(_attrs), do: {:error, :media_storage_unavailable}

  @impl true
  def complete_upload(_attrs), do: {:error, :media_storage_unavailable}

  @impl true
  def get_download_url(_attrs), do: {:error, :media_storage_unavailable}
end

defmodule MediaService.Storage.MinioAdapter do
  @moduledoc """
  MinIO/S3 presigned URL adapter.

  This adapter signs PUT and GET URLs with AWS Signature Version 4. It does not
  perform live network calls or upload file bytes.
  """

  @behaviour MediaService.Storage

  @algorithm "AWS4-HMAC-SHA256"
  @service "s3"

  @impl true
  def create_upload(attrs) do
    with {:ok, config} <- config(),
         {:ok, upload_url} <- presigned_url("PUT", attrs["object_key"], config) do
      {:ok,
       %{
         media_id: attrs["media_id"],
         owner_user_id: attrs["owner_user_id"],
         object_key: attrs["object_key"],
         upload_url: upload_url,
         expires_at: attrs["expires_at"],
         status: "pending"
       }}
    end
  end

  @impl true
  def complete_upload(attrs) do
    {:ok,
     %{
       media_id: attrs["media_id"],
       owner_user_id: attrs["owner_user_id"],
       object_key: attrs["object_key"],
       status: "ready"
     }}
  end

  @impl true
  def get_download_url(attrs) do
    with {:ok, config} <- config(),
         {:ok, download_url} <- presigned_url("GET", attrs["object_key"], config) do
      {:ok,
       %{
         media_id: attrs["media_id"],
         owner_user_id: attrs["owner_user_id"],
         object_key: attrs["object_key"],
         download_url: download_url,
         expires_at: attrs["expires_at"]
       }}
    end
  end

  defp presigned_url(method, object_key, config) do
    now = Keyword.get(config, :now) || DateTime.utc_now()
    amz_date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    date_stamp = Calendar.strftime(now, "%Y%m%d")
    credential_scope = "#{date_stamp}/#{config[:region]}/#{@service}/aws4_request"
    canonical_uri = canonical_uri(config, object_key)
    # Sign against the browser-reachable public endpoint when set (so the SigV4 host header matches the
    # host the browser actually PUTs/GETs); fall back to the internal endpoint otherwise.
    endpoint_uri = URI.parse(config[:public_endpoint] || config[:endpoint])

    host =
      case endpoint_uri.port do
        nil -> endpoint_uri.host
        port -> "#{endpoint_uri.host}:#{port}"
      end

    query_params = %{
      "X-Amz-Algorithm" => @algorithm,
      "X-Amz-Content-Sha256" => "UNSIGNED-PAYLOAD",
      "X-Amz-Credential" => "#{config[:access_key_id]}/#{credential_scope}",
      "X-Amz-Date" => amz_date,
      "X-Amz-Expires" => Integer.to_string(config[:url_expires_seconds]),
      "X-Amz-SignedHeaders" => "host"
    }

    canonical_query = canonical_query_string(query_params)

    canonical_request = [
      method,
      canonical_uri,
      canonical_query,
      "host:#{host}\n",
      "host",
      "UNSIGNED-PAYLOAD"
    ]

    string_to_sign = [
      @algorithm,
      amz_date,
      credential_scope,
      sha256_hex(Enum.join(canonical_request, "\n"))
    ]

    signature =
      config[:secret_access_key]
      |> signing_key(date_stamp, config[:region])
      |> hmac_sha256(Enum.join(string_to_sign, "\n"))
      |> Base.encode16(case: :lower)

    url = %URI{
      scheme: endpoint_uri.scheme || "http",
      host: endpoint_uri.host,
      port: endpoint_uri.port,
      path: canonical_uri,
      query: canonical_query_string(Map.put(query_params, "X-Amz-Signature", signature))
    }

    {:ok, URI.to_string(url)}
  rescue
    _ -> {:error, :media_storage_unavailable}
  end

  defp canonical_uri(config, object_key) do
    bucket = config[:bucket]
    encoded_key = encode_path(object_key)

    if config[:path_style] do
      "/" <> Enum.join([uri_encode(bucket), encoded_key], "/")
    else
      "/" <> encoded_key
    end
  end

  defp canonical_query_string(params) do
    params
    |> Enum.sort_by(fn {key, value} -> {to_string(key), to_string(value)} end)
    |> Enum.map_join("&", fn {key, value} ->
      "#{uri_encode(key)}=#{uri_encode(value)}"
    end)
  end

  defp encode_path(object_key) do
    object_key
    |> String.split("/", trim: true)
    |> Enum.map_join("/", &uri_encode/1)
  end

  defp signing_key(secret_access_key, date_stamp, region) do
    ("AWS4" <> secret_access_key)
    |> hmac_sha256(date_stamp)
    |> hmac_sha256(region)
    |> hmac_sha256(@service)
    |> hmac_sha256("aws4_request")
  end

  defp hmac_sha256(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp sha256_hex(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp uri_encode(value) do
    value
    |> to_string()
    |> URI.encode(&URI.char_unreserved?/1)
  end

  defp config do
    config = Application.get_env(:media_service, :minio, [])

    with {:ok, endpoint} <- required_config(config, :endpoint),
         {:ok, bucket} <- required_config(config, :bucket),
         {:ok, access_key_id} <- required_config(config, :access_key_id),
         {:ok, secret_access_key} <- required_config(config, :secret_access_key),
         {:ok, region} <- required_config(config, :region) do
      {:ok,
       [
         endpoint: endpoint,
         # Optional: browser-reachable host used ONLY to sign presigned URLs (SigV4 host match). When
         # unset, signing falls back to :endpoint. Internal/server-side ops keep using :endpoint.
         public_endpoint: Keyword.get(config, :public_endpoint),
         bucket: bucket,
         access_key_id: access_key_id,
         secret_access_key: secret_access_key,
         region: region,
         url_expires_seconds: Keyword.get(config, :url_expires_seconds, 900),
         path_style: Keyword.get(config, :path_style, true),
         now: Keyword.get(config, :now)
       ]}
    end
  end

  defp required_config(config, key) do
    case Keyword.get(config, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :media_storage_unavailable}
    end
  end
end

defmodule MediaService.Storage.InMemoryAdapter do
  @moduledoc """
  Test-safe in-memory media storage adapter.
  """

  @behaviour MediaService.Storage

  use Agent

  @name __MODULE__

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: @name)
  end

  def reset do
    ensure_started()
    Agent.update(@name, fn _uploads -> %{} end)
  end

  @impl true
  def create_upload(attrs) do
    ensure_started()

    upload = %{
      media_id: attrs["media_id"],
      owner_user_id: attrs["owner_user_id"],
      object_key: attrs["object_key"],
      upload_url: storage_url("upload", attrs["object_key"]),
      expires_at: attrs["expires_at"],
      status: "pending"
    }

    Agent.update(@name, &Map.put(&1, attrs["media_id"], upload))

    {:ok, upload}
  end

  @impl true
  def complete_upload(attrs) do
    ensure_started()

    Agent.get_and_update(@name, fn uploads ->
      upload =
        uploads
        |> Map.get(attrs["media_id"], %{
          media_id: attrs["media_id"],
          owner_user_id: attrs["owner_user_id"],
          object_key: attrs["object_key"]
        })
        |> Map.merge(%{status: "ready", object_key: attrs["object_key"]})

      {{:ok, upload}, Map.put(uploads, attrs["media_id"], upload)}
    end)
  end

  @impl true
  def get_download_url(attrs) do
    ensure_started()

    {:ok,
     %{
       media_id: attrs["media_id"],
       owner_user_id: attrs["owner_user_id"],
       object_key: attrs["object_key"],
       download_url: storage_url("download", attrs["object_key"]),
       expires_at: attrs["expires_at"]
     }}
  end

  defp storage_url(action, object_key) do
    "http://localhost:9000/chat-media/#{URI.encode(object_key)}?action=#{action}"
  end

  defp ensure_started do
    case Process.whereis(@name) do
      nil ->
        {:ok, _pid} = start_link()
        :ok

      _pid ->
        :ok
    end
  end
end
