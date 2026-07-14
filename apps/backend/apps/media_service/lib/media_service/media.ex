defmodule MediaService.Media do
  @moduledoc """
  Media upload/download boundary.

  Live MinIO/S3 URL signing is behind the storage adapter boundary and is not
  enabled by default.
  """

  alias MediaService.Repo
  alias MediaService.Schemas.MediaAsset
  alias MediaService.Storage

  # Kept in sync with the frontend allowedMediaTypes set (apps/web chat page). video/quicktime (.mov)
  # is what Mac screen recordings / iPhone clips use; video/webm + video/x-matroska (.mkv) are common too.
  # audio/webm + audio/ogg are the typical MediaRecorder voice-message outputs (Chrome/Firefox); Safari
  # records audio/mp4 (already allowed above).
  @allowed_content_types MapSet.new([
                           "image/jpeg",
                           "image/png",
                           "image/webp",
                           "application/pdf",
                           "audio/mpeg",
                           "audio/mp4",
                           "audio/webm",
                           "audio/ogg",
                           "video/mp4",
                           "video/quicktime",
                           "video/webm",
                           "video/x-matroska"
                         ])

  @type media_attrs :: map()
  @type result :: {:ok, map()} | {:error, atom()}

  @callback create_upload(media_attrs()) :: result()
  @callback complete_upload(media_attrs()) :: result()
  @callback get_download_url(media_attrs()) :: result()

  # Authorization for `message` / `group_avatar` (membership / owner-admin) is enforced at the GATEWAY
  # before this is called — media_service can't reach conversation_service in prod. Here we persist the
  # authoritative media_assets row (tenant + owner + purpose + server object_key), then presign the PUT.
  # `app_id` is required (the caller's session tenant); `purpose` defaults to "message"; `conversation_id`
  # is optional this slice (Phase 5 frontend will always send it — see the enforce-when-present note above).
  def create_upload(attrs) do
    with {:ok, owner_user_id} <- required_attr(attrs, "owner_user_id"),
         {:ok, purpose} <- fetch_purpose(attrs),
         {:ok, filename} <- required_attr(attrs, "filename"),
         {:ok, content_type} <- required_content_type(attrs),
         {:ok, size_bytes} <- required_size(attrs) do
      media_id = generate_uuid()
      object_key = object_key(owner_user_id, media_id, filename)
      conversation_id = optional_attr(attrs, "conversation_id")

      upload_attrs = %{
        "media_id" => media_id,
        "owner_user_id" => owner_user_id,
        "filename" => filename,
        "content_type" => content_type,
        "size_bytes" => size_bytes,
        "object_key" => object_key,
        "expires_at" => expires_at()
      }

      if media_persistence_enabled?() do
        # app_id is required only on the persisting path (placeholder/dev mode has no tenant + no INSERT).
        with {:ok, app_id} <- required_attr(attrs, "app_id"),
             {:ok, _asset} <-
               insert_media_asset(
                 media_id,
                 app_id,
                 owner_user_id,
                 conversation_id,
                 purpose,
                 object_key,
                 content_type,
                 size_bytes
               ),
             {:ok, upload} <- Storage.create_upload(upload_attrs) do
          {:ok, upload_response(upload, upload_attrs)}
        end
      else
        {:ok, placeholder_upload_response(upload_attrs)}
      end
    end
  end

  # Take `media_id` + the caller (`owner_user_id`) + `app_id` ONLY — NEVER a client object_key. Resolve the
  # row server-side scoped to the tenant, verify the caller OWNS it (else 404 — no existence reveal), and
  # flip it to "ready". Idempotent: completing an already-ready asset succeeds.
  def complete_upload(attrs) do
    with {:ok, media_id} <- required_attr(attrs, "media_id"),
         {:ok, owner_user_id} <- required_attr(attrs, "owner_user_id") do
      if media_persistence_enabled?() do
        with {:ok, app_id} <- required_attr(attrs, "app_id") do
          complete_persisted(media_id, app_id, owner_user_id)
        end
      else
        {:ok, complete_response(%{"media_id" => media_id})}
      end
    end
  end

  # Presign a download by media_id (scoped to the caller's app_id). The object_key is read FROM THE ROW —
  # NEVER from the request. A client-supplied object_key is ignored (the frontend still sends one until
  # Phase 5). Authorization (ownership / membership) happens at the gateway BEFORE this is called.
  def get_download_url(attrs) do
    with {:ok, media_id} <- required_attr(attrs, "media_id") do
      if media_persistence_enabled?() do
        with {:ok, app_id} <- required_attr(attrs, "app_id") do
          # Optional expected purpose: an avatar/message call-site refuses to presign an asset of the wrong
          # purpose (so a poisoned avatar_media_id can't presign a message attachment). Absent → no check
          # (media_controller.download already authorized the specific asset).
          download_persisted(media_id, app_id, optional_attr(attrs, "purpose"))
        end
      else
        {:ok, placeholder_download_response(%{"media_id" => media_id, "expires_at" => expires_at()})}
      end
    end
  end

  # Read-path authorization support: resolve an asset's purpose + owner + conversation (scoped to app_id)
  # so the gateway can authorize BEFORE any URL is minted. NEVER returns object_key. (media_id, app_id) only.
  def get_asset(attrs) do
    with {:ok, media_id} <- required_attr(attrs, "media_id"),
         {:ok, app_id} <- required_attr(attrs, "app_id") do
      if media_persistence_enabled?() do
        lookup_asset(media_id, app_id)
      else
        {:error, :not_found}
      end
    end
  end

  def media_persistence_enabled? do
    Application.get_env(:media_service, :media_persistence, false) ||
      System.get_env("MEDIA_DB_BACKED") in ["true", "1", "yes"]
  end

  # --- media_assets persistence (write path) -------------------------------------------------------

  defp insert_media_asset(
         media_id,
         app_id,
         owner_user_id,
         conversation_id,
         purpose,
         object_key,
         mime_type,
         size_bytes
       ) do
    now = DateTime.utc_now()

    %{
      id: media_id,
      app_id: app_id,
      owner_user_id: owner_user_id,
      conversation_id: conversation_id,
      purpose: purpose,
      storage_provider: storage_provider(),
      bucket: bucket(),
      object_key: object_key,
      mime_type: mime_type,
      size_bytes: size_bytes,
      status: "created",
      created_at: now,
      updated_at: now
    }
    |> MediaAsset.create_changeset()
    |> Repo.insert()
    |> case do
      {:ok, asset} -> {:ok, asset}
      {:error, _changeset} -> {:error, :media_invalid}
    end
  end

  defp download_persisted(media_id, app_id, expected_purpose) do
    case Repo.get_by(MediaAsset, id: media_id, app_id: app_id) do
      nil ->
        {:error, :not_found}

      %MediaAsset{} = asset ->
        if purpose_ok?(asset, expected_purpose) do
          expires_at = expires_at()

          case Storage.get_download_url(%{
                 "object_key" => asset.object_key,
                 "media_id" => media_id,
                 "expires_at" => expires_at
               }) do
            {:ok, media} -> {:ok, download_response(media, asset, expires_at)}
            {:error, reason} -> {:error, reason}
          end
        else
          # Wrong purpose (e.g. an avatar call-site pointed at a message asset) → 404, no presign.
          {:error, :not_found}
        end
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  defp purpose_ok?(_asset, nil), do: true
  defp purpose_ok?(%MediaAsset{purpose: purpose}, expected), do: purpose == expected

  defp lookup_asset(media_id, app_id) do
    case Repo.get_by(MediaAsset, id: media_id, app_id: app_id) do
      nil ->
        {:error, :not_found}

      %MediaAsset{} = asset ->
        {:ok,
         %{
           media_id: asset.id,
           purpose: asset.purpose,
           owner_user_id: asset.owner_user_id,
           conversation_id: asset.conversation_id,
           # status lets the avatar-set path require a completed ("ready") asset, not a pending upload.
           status: asset.status
         }}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  defp complete_persisted(media_id, app_id, owner_user_id) do
    case Repo.get_by(MediaAsset, id: media_id, app_id: app_id) do
      nil ->
        {:error, :not_found}

      %MediaAsset{owner_user_id: ^owner_user_id} = asset ->
        with {:ok, real_size} <- verify_uploaded_size(asset) do
          mark_ready(asset, real_size)
        end

      %MediaAsset{} ->
        # A different owner's asset — 404, never reveal that it exists.
        {:error, :not_found}
    end
  rescue
    # A non-UUID media_id casts-errors on the lookup; treat as not found (no 500).
    Ecto.Query.CastError -> {:error, :not_found}
  end

  @doc """
  Verify the ACTUAL uploaded bytes before an asset may become `ready`.

  `create_upload` caps on the size the CLIENT CLAIMS, but the bytes go straight to storage via a presigned
  PUT — the backend never sees them. So a client could claim 100 bytes, PUT 5 GB, and complete. The claim is
  advisory; THIS is the security boundary: HEAD the object for its real `Content-Length` and enforce
  `max_size_bytes()` on that.

  Cap-only, deliberately: we do NOT require the real size to match the claim. Under-claiming while staying
  within the cap is harmless, and an exact-match rule would break clients whose compression/encoding shifts
  the byte count. The cap is what protects storage.

  FAILS CLOSED. An unverifiable upload (transport error, unreadable header, unexpected status) is NEVER
  marked ready — `:verify_failed` is transient and the client may simply call complete again.

  HONEST LIMITATION: the bytes are uploaded BEFORE they can be rejected, then deleted. An attacker can still
  burn BANDWIDTH and briefly occupy storage. What is closed is PERMANENT storage abuse: an over-cap object is
  removed and its asset never becomes `ready`, so it can never be attached to a message or downloaded. A
  content-length-range condition on the upload itself would reject at the edge, but that needs a POST-policy
  (form upload) instead of a presigned PUT — the stronger future option, out of scope here.
  """
  def verify_uploaded_size(%MediaAsset{} = asset) do
    case Storage.head_object(%{"object_key" => asset.object_key}) do
      {:ok, %{size_bytes: real_size}} when is_integer(real_size) ->
        if real_size > max_size_bytes() do
          # Over cap: remove the bytes (best-effort) and refuse. A FAILED cleanup must still refuse — an
          # orphaned object is far better than a ready, usable over-cap asset.
          _ = Storage.delete_object(%{"object_key" => asset.object_key})
          {:error, :media_too_large}
        else
          {:ok, real_size}
        end

      # The presigned PUT never happened — there is nothing to complete.
      {:error, :upload_not_found} ->
        {:error, :upload_not_found}

      # Unverifiable → fail closed.
      _ ->
        {:error, :verify_failed}
    end
  end

  # Idempotent: an already-ready asset returns success without a redundant write (and without re-HEADing —
  # the size was already verified when it first became ready).
  defp mark_ready(%MediaAsset{status: "ready"} = asset, _real_size),
    do: {:ok, complete_response(%{"media_id" => asset.id})}

  defp mark_ready(%MediaAsset{} = asset, real_size) do
    asset
    # Overwrite size_bytes with the MEASURED size, not the client's claim — usage metering sums this column,
    # so a false claim would otherwise under-report (or inflate) an app's storage forever.
    |> MediaAsset.ready_changeset(real_size, DateTime.utc_now())
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, complete_response(%{"media_id" => updated.id})}
      {:error, _changeset} -> {:error, :media_invalid}
    end
  end

  defp storage_provider, do: "minio"

  defp bucket do
    :media_service
    |> Application.get_env(:minio, [])
    |> Keyword.get(:bucket, "chat-media")
  end

  defp fetch_purpose(attrs) do
    case get_attr(attrs, "purpose") do
      nil -> {:ok, "message"}
      "" -> {:ok, "message"}
      purpose when purpose in ["message", "user_avatar", "group_avatar"] -> {:ok, purpose}
      _ -> {:error, :media_invalid}
    end
  end

  defp optional_attr(attrs, key) do
    case get_attr(attrs, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp upload_response(upload, attrs) do
    %{
      media_id: upload[:media_id] || attrs["media_id"],
      # TODO(phase-5): stop returning object_key. The current frontend puts it into message metadata and
      # every avatar flow reads it (apps/web chat/page.tsx, MyProfileModal, ConversationDetailsPanel), so
      # removing it now breaks live uploads. The read path (Phase 2) will resolve the key server-side from
      # media_id, and Phase 5 migrates the frontend off this field.
      object_key: upload[:object_key] || attrs["object_key"],
      upload_url: upload[:upload_url],
      expires_at: iso8601(upload[:expires_at] || attrs["expires_at"])
    }
  end

  defp placeholder_upload_response(attrs) do
    %{
      media_id: attrs["media_id"],
      object_key: attrs["object_key"],
      upload_url: "https://media.placeholder.local/uploads/#{attrs["media_id"]}",
      expires_at: iso8601(attrs["expires_at"])
    }
  end

  defp complete_response(media) do
    %{
      media_id: media[:media_id] || media["media_id"],
      status: "ready"
    }
  end

  # The persisted download response — mime_type comes from the ROW; object_key + owner_user_id are NEVER
  # returned (they'd re-leak the capability we just stopped trusting from the client).
  defp download_response(media, asset, expires_at) do
    %{
      media_id: asset.id,
      download_url: media[:download_url],
      expires_at: iso8601(expires_at),
      mime_type: asset.mime_type
    }
  end

  defp placeholder_download_response(attrs) do
    %{
      media_id: attrs["media_id"],
      download_url: "https://media.placeholder.local/downloads/#{attrs["media_id"]}",
      expires_at: iso8601(attrs["expires_at"])
    }
  end

  defp required_content_type(attrs) do
    with {:ok, content_type} <- required_attr(attrs, "content_type"),
         base_type = base_content_type(content_type),
         true <- MapSet.member?(@allowed_content_types, base_type) do
      {:ok, base_type}
    else
      _ -> {:error, :media_invalid}
    end
  end

  # MediaRecorder sends parameterized types like "audio/webm; codecs=opus"; the allow-list holds base
  # types, so normalize to the base (everything before the first ";", trimmed) before the check — and
  # store that base type (defense in depth even though the frontend already strips it).
  defp base_content_type(content_type) do
    content_type
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
  end

  defp required_size(attrs) do
    with {:ok, size} <- parse_required_size(get_attr(attrs, "size_bytes")) do
      # Single overall cap so a large video can't fill object storage unbounded. Read at RUNTIME via
      # System.get_env (point-of-use, never config.exs-baked) — MEDIA_MAX_SIZE_BYTES overrides the
      # default. Images are additionally compressed client-side, so they're well under this.
      if size > max_size_bytes(), do: {:error, :media_too_large}, else: {:ok, size}
    end
  end

  defp parse_required_size(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp parse_required_size(value) when is_binary(value), do: parse_size(value)
  defp parse_required_size(_), do: {:error, :media_invalid}

  defp parse_size(value) do
    case Integer.parse(value) do
      {size, ""} when size > 0 -> {:ok, size}
      _ -> {:error, :media_invalid}
    end
  end

  # Default 100 MB. Override with MEDIA_MAX_SIZE_BYTES (bytes).
  @default_max_size_bytes 100 * 1024 * 1024

  defp max_size_bytes do
    case System.get_env("MEDIA_MAX_SIZE_BYTES") do
      value when is_binary(value) and value != "" ->
        case Integer.parse(value) do
          {bytes, _rest} when bytes > 0 -> bytes
          _ -> @default_max_size_bytes
        end

      _ ->
        @default_max_size_bytes
    end
  end

  defp required_attr(attrs, key) do
    case get_attr(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :media_invalid}
    end
  end

  defp object_key(owner_user_id, media_id, filename) do
    "media/#{owner_user_id}/#{media_id}/#{safe_filename(filename)}"
  end

  defp safe_filename(filename) do
    filename
    |> Path.basename()
    |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
    |> case do
      "" -> "upload"
      value -> value
    end
  end

  defp expires_at do
    expires_in_seconds =
      :media_service
      |> Application.get_env(:minio, [])
      |> Keyword.get(:url_expires_seconds, 900)

    DateTime.utc_now()
    |> DateTime.add(expires_in_seconds, :second)
    |> DateTime.truncate(:second)
  end

  defp get_attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))

  defp generate_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = Bitwise.band(c, 0x0FFF) |> Bitwise.bor(0x4000)
    d = Bitwise.band(d, 0x3FFF) |> Bitwise.bor(0x8000)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [
      a,
      b,
      c,
      d,
      e
    ])
    |> IO.iodata_to_binary()
    |> String.downcase()
  end

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(value), do: value
end
