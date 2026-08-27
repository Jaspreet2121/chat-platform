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
  @callback head_object(attrs()) :: result()
  @callback delete_object(attrs()) :: result()

  # S3 multipart (112). The object only exists once complete_multipart_upload/1 succeeds, so an
  # abandoned upload leaves no object at all — which is what keeps a half-finished media row unusable.
  @callback create_multipart_upload(attrs()) :: result()
  @callback presign_upload_parts(attrs()) :: result()
  @callback complete_multipart_upload(attrs()) :: result()
  @callback abort_multipart_upload(attrs()) :: result()

  # Optional so an existing test double implementing only the single-PUT surface keeps compiling.
  @optional_callbacks create_multipart_upload: 1,
                      presign_upload_parts: 1,
                      complete_multipart_upload: 1,
                      abort_multipart_upload: 1

  def create_upload(attrs), do: adapter().create_upload(attrs)
  def complete_upload(attrs), do: adapter().complete_upload(attrs)
  def get_download_url(attrs), do: adapter().get_download_url(attrs)

  @doc """
  The REAL byte size of a stored object: `{:ok, %{size_bytes: n}}` | `{:error, :upload_not_found}` (the PUT
  never happened) | `{:error, :verify_failed}` (unreachable / unreadable — callers must fail CLOSED).
  """
  def head_object(attrs), do: adapter().head_object(attrs)

  @doc "Remove a stored object. Best-effort cleanup after a rejected upload."
  def delete_object(attrs), do: adapter().delete_object(attrs)

  @doc "Begin a multipart upload. → %{upload_id: String.t()}."
  def create_multipart_upload(attrs), do: adapter().create_multipart_upload(attrs)

  @doc "Presigned PUT URLs for a window of part numbers. → %{parts: [%{part_number, url}]}."
  def presign_upload_parts(attrs), do: adapter().presign_upload_parts(attrs)

  @doc "Assemble the parts into the final object. → %{object_key: String.t()}."
  def complete_multipart_upload(attrs), do: adapter().complete_multipart_upload(attrs)

  @doc "Discard an unfinished multipart upload and free its parts. Idempotent."
  def abort_multipart_upload(attrs), do: adapter().abort_multipart_upload(attrs)

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

  @impl true
  def head_object(_attrs), do: {:error, :media_storage_unavailable}

  @impl true
  def delete_object(_attrs), do: {:error, :media_storage_unavailable}

  @impl true
  def create_multipart_upload(_attrs), do: {:error, :media_storage_unavailable}

  @impl true
  def presign_upload_parts(_attrs), do: {:error, :media_storage_unavailable}

  @impl true
  def complete_multipart_upload(_attrs), do: {:error, :media_storage_unavailable}

  @impl true
  def abort_multipart_upload(_attrs), do: {:error, :media_storage_unavailable}
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
    # A server-side uploader (attrs["internal"]) signs against the INTERNAL endpoint so its PUT
    # reaches MinIO directly on the docker network; a browser upload keeps the public-host signature.
    with {:ok, config} <- config(),
         config = if(attrs["internal"], do: internal(config), else: config),
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
         config = override_url_expiry(config, attrs["url_expires_seconds"]),
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

  @impl true
  def head_object(%{"object_key" => object_key})
      when is_binary(object_key) and object_key != "" do
    with {:ok, config} <- config(),
         {:ok, url} <- presigned_url("HEAD", object_key, internal(config)),
         {:ok, status, headers} <- SharedInfra.HttpClient.head(url) do
      case status do
        200 ->
          case content_length(headers) do
            nil -> {:error, :verify_failed}
            size -> {:ok, %{object_key: object_key, size_bytes: size}}
          end

        # The PUT never happened (or the key is wrong) — there is nothing to complete.
        404 ->
          {:error, :upload_not_found}

        # Anything else (403 on a bad signature, 5xx from MinIO) is UNVERIFIABLE, not "fine".
        _other ->
          {:error, :verify_failed}
      end
    else
      {:error, :upload_not_found} -> {:error, :upload_not_found}
      # A transport / config failure must NOT read as "no object" — fail closed.
      _ -> {:error, :verify_failed}
    end
  end

  def head_object(_attrs), do: {:error, :verify_failed}

  @impl true
  def delete_object(%{"object_key" => object_key})
      when is_binary(object_key) and object_key != "" do
    with {:ok, config} <- config(),
         {:ok, url} <- presigned_url("DELETE", object_key, internal(config)),
         {:ok, status, _headers} <- SharedInfra.HttpClient.delete(url) do
      # S3/MinIO DELETE is idempotent: 204 on success, 404 if already gone — both mean "not there".
      if status in [200, 202, 204, 404], do: :ok, else: {:error, :media_storage_unavailable}
    else
      _ -> {:error, :media_storage_unavailable}
    end
  end

  def delete_object(_attrs), do: {:error, :media_storage_unavailable}

  # ---- S3 multipart (112) -------------------------------------------------------------------------
  #
  # Four operations, and the endpoint split matters in each:
  #   * create / complete / abort are SERVER-SIDE calls from the media service, so they presign
  #     against the INTERNAL host (same reason as head/delete — the signed host must equal the host
  #     we actually connect to);
  #   * presign_upload_parts hands URLs to a CLIENT, so those keep the PUBLIC-host signature.
  #
  # Verified against the deployed MinIO: CreateMultipartUpload, presigned UploadPart (unauthenticated
  # PUT), and CompleteMultipartUpload all work, and the assembled object's byte count is exact.

  @impl true
  def create_multipart_upload(%{"object_key" => object_key})
      when is_binary(object_key) and object_key != "" do
    with {:ok, config} <- config(),
         {:ok, url} <- presigned_url("POST", object_key, internal(config), %{"uploads" => ""}),
         {:ok, status, _headers, body} <- SharedInfra.HttpClient.raw(:post, url) do
      case {status, extract_tag(body, "UploadId")} do
        {200, upload_id} when is_binary(upload_id) and upload_id != "" ->
          {:ok, %{upload_id: upload_id, object_key: object_key}}

        _ ->
          {:error, :media_storage_unavailable}
      end
    else
      _ -> {:error, :media_storage_unavailable}
    end
  end

  def create_multipart_upload(_attrs), do: {:error, :media_storage_unavailable}

  @impl true
  def presign_upload_parts(%{
        "object_key" => object_key,
        "upload_id" => upload_id,
        "part_numbers" => numbers
      })
      when is_binary(object_key) and object_key != "" and is_binary(upload_id) and
             is_list(numbers) do
    with {:ok, config} <- config() do
      parts =
        Enum.reduce_while(numbers, [], fn number, acc ->
          extra = %{"partNumber" => Integer.to_string(number), "uploadId" => upload_id}

          case presigned_url("PUT", object_key, config, extra) do
            {:ok, url} -> {:cont, [%{part_number: number, url: url} | acc]}
            _ -> {:halt, :error}
          end
        end)

      case parts do
        :error -> {:error, :media_storage_unavailable}
        list -> {:ok, %{parts: Enum.reverse(list)}}
      end
    end
  end

  def presign_upload_parts(_attrs), do: {:error, :media_storage_unavailable}

  @impl true
  def complete_multipart_upload(%{
        "object_key" => object_key,
        "upload_id" => upload_id,
        "parts" => parts
      })
      when is_binary(object_key) and object_key != "" and is_binary(upload_id) and is_list(parts) do
    with {:ok, config} <- config(),
         {:ok, url} <-
           presigned_url("POST", object_key, internal(config), %{"uploadId" => upload_id}),
         {:ok, status, _headers, body} <-
           SharedInfra.HttpClient.raw(:post, url,
             body: complete_xml(parts),
             headers: [{"content-type", "application/xml"}]
           ) do
      # S3 can answer 200 with an <Error> document (it streams whitespace while assembling, then
      # reports failure). Treating that as success is how a corrupt/absent object gets marked ready.
      cond do
        status == 200 and extract_tag(body, "Error") == nil and
            is_binary(extract_tag(body, "ETag")) ->
          {:ok, %{object_key: object_key}}

        status == 200 ->
          {:error, :multipart_incomplete}

        status in [400, 404] ->
          {:error, :multipart_incomplete}

        true ->
          {:error, :media_storage_unavailable}
      end
    else
      _ -> {:error, :media_storage_unavailable}
    end
  end

  def complete_multipart_upload(_attrs), do: {:error, :media_storage_unavailable}

  @impl true
  def abort_multipart_upload(%{"object_key" => object_key, "upload_id" => upload_id})
      when is_binary(object_key) and object_key != "" and is_binary(upload_id) do
    with {:ok, config} <- config(),
         {:ok, url} <-
           presigned_url("DELETE", object_key, internal(config), %{"uploadId" => upload_id}),
         {:ok, status, _headers, _body} <- SharedInfra.HttpClient.raw(:delete, url) do
      # Idempotent, like delete_object: 204 on success, 404 when it is already gone.
      if status in [200, 202, 204, 404], do: :ok, else: {:error, :media_storage_unavailable}
    else
      _ -> {:error, :media_storage_unavailable}
    end
  end

  def abort_multipart_upload(_attrs), do: {:error, :media_storage_unavailable}

  # The CompleteMultipartUpload body. Parts MUST be ascending by part number — S3 rejects any other
  # order — and the ETag is echoed back exactly as the UploadPart response gave it (quotes included).
  defp complete_xml(parts) do
    body =
      parts
      |> Enum.sort_by(& &1["part_number"])
      |> Enum.map_join(fn part ->
        "<Part><PartNumber>#{part["part_number"]}</PartNumber><ETag>#{escape_xml(part["etag"])}</ETag></Part>"
      end)

    "<CompleteMultipartUpload>" <> body <> "</CompleteMultipartUpload>"
  end

  defp escape_xml(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # Enough XML for the two values we read back. A real parser would be overkill for two tags in a
  # response we generated the request for.
  defp extract_tag(body, tag) when is_binary(body) do
    case Regex.run(~r{<#{tag}>(.*?)</#{tag}>}s, body) do
      [_, value] -> value
      _ -> nil
    end
  end

  defp extract_tag(_body, _tag), do: nil

  # THE ENDPOINT SUBTLETY. `presigned_url/3` signs against `public_endpoint || endpoint` because a BROWSER
  # PUT/GET must have the SigV4 host match the host it actually connects to. A SERVER-SIDE HEAD/DELETE runs
  # from the media service, which reaches MinIO directly on the internal network — so signing against the
  # public host while connecting internally would make the Host header disagree with the signed host and
  # MinIO would reject it (SignatureDoesNotMatch). Dropping :public_endpoint makes presigned_url fall back
  # to :endpoint for BOTH the signature and the URL it builds, so they always agree.
  defp internal(config), do: Keyword.put(config, :public_endpoint, nil)

  defp content_length(headers) do
    headers
    |> Enum.find_value(fn {name, value} ->
      if String.downcase(to_string(name)) == "content-length", do: value
    end)
    |> normalize_header_value()
    |> case do
      nil ->
        nil

      raw ->
        case Integer.parse(to_string(raw)) do
          {size, _} when size >= 0 -> size
          _ -> nil
        end
    end
  end

  # Req returns header values as a LIST of strings (e.g. {"content-length", ["42"]}).
  defp normalize_header_value([value | _]), do: value
  defp normalize_header_value([]), do: nil
  defp normalize_header_value(value), do: value

  # Per-call presign TTL override (status media uses 300s; everything else keeps the config default).
  defp override_url_expiry(config, seconds) when is_integer(seconds) and seconds > 0,
    do: Keyword.put(config, :url_expires_seconds, seconds)

  defp override_url_expiry(config, _seconds), do: config

  # `extra_query` folds additional S3 query parameters (partNumber, uploadId, …) into the CANONICAL
  # query string BEFORE signing, which is what SigV4 requires — a parameter appended to the URL after
  # signing is not covered by the signature and MinIO rejects it. Defaults to none, so every existing
  # caller signs exactly the same bytes it always did.
  defp presigned_url(method, object_key, config, extra_query \\ %{}) do
    now = Keyword.get(config, :now) || DateTime.utc_now()
    amz_date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    date_stamp = Calendar.strftime(now, "%Y%m%d")
    credential_scope = "#{date_stamp}/#{config[:region]}/#{@service}/aws4_request"
    canonical_uri = canonical_uri(config, object_key)

    # Sign against the browser-reachable public endpoint when set (so the SigV4 host header matches the
    # host the browser actually PUTs/GETs); fall back to the internal endpoint otherwise.
    endpoint_uri = URI.parse(config[:public_endpoint] || config[:endpoint])
    host = canonical_host(endpoint_uri)

    query_params = %{
      "X-Amz-Algorithm" => @algorithm,
      "X-Amz-Content-Sha256" => "UNSIGNED-PAYLOAD",
      "X-Amz-Credential" => "#{config[:access_key_id]}/#{credential_scope}",
      "X-Amz-Date" => amz_date,
      "X-Amz-Expires" => Integer.to_string(config[:url_expires_seconds]),
      "X-Amz-SignedHeaders" => "host"
    }

    query_params = Map.merge(query_params, extra_query)
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

  # SigV4 host for the canonical request. Must match the Host header the client will actually send:
  # browsers (and URI.to_string) omit scheme-default ports (443 for https, 80 for http), so the port is
  # included ONLY when non-default (e.g. minio:9000 / localhost:9000). Signing "host:443" while the
  # browser sends a bare host causes MinIO to reject with SignatureDoesNotMatch.
  @doc false
  def canonical_host(%URI{} = uri) do
    case uri.port do
      nil ->
        uri.host

      port ->
        if port == URI.default_port(uri.scheme || "http"),
          do: uri.host,
          else: "#{uri.host}:#{port}"
    end
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

  # UNLINKED on purpose. This lazy-start runs inside whatever process first calls the adapter — in
  # tests, a TEST PROCESS. `Agent.start_link` would tie the shared agent's life to that test: the agent
  # dies with it, and the next caller races the death (whereis says alive, the call says no process).
  # That race produced real CI flakes ("join crashed" in channels_test; sandbox checkout deaths). An
  # explicitly supervised start_link/1 remains available for supervision trees.
  defp ensure_started do
    case Process.whereis(@name) do
      nil ->
        case Agent.start(fn -> %{} end, name: @name) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  # In-memory: nothing is really stored, so verification is not meaningful here. Tests that exercise the
  # size-verification path swap in their own adapter (see MediaService.CompleteVerifyTest).
  @impl true
  def head_object(_attrs), do: {:error, :verify_failed}

  @impl true
  def delete_object(_attrs), do: :ok
end
