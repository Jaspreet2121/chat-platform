defmodule MediaService.Media do
  @moduledoc """
  Media upload/download boundary.

  Live MinIO/S3 URL signing is behind the storage adapter boundary and is not
  enabled by default.
  """

  alias MediaService.Repo
  alias MediaService.Schemas.MediaAsset
  alias MediaService.Storage

  # Status presign TTL (seconds) — deliberately shorter than the default chat-media TTL.
  @status_url_expires_seconds 300

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

  # PURPOSES THAT MUST CARRY A CONVERSATION ANCHOR AT CREATE.
  #
  # A sealed attachment's media_id rides INSIDE the encrypted frame, so no message row ever references
  # it and the ONLY thing that can authorize a recipient is the conversation the ciphertext was
  # uploaded for. An asset created without one is unreadable by every recipient forever — which is
  # exactly what happened: 33 of 37 sealed assets in two days were minted anchorless and 404'd.
  # Refusing loudly at create is the whole point; a silently-conversationless sealed asset is a bug
  # that only surfaces days later on someone else's device.
  #
  # "message" is DELIBERATELY NOT in this list yet. Live traffic shows 38 of 65 plaintext message
  # uploads arriving with no conversation_id (older Android builds), so requiring it today would turn
  # a sealed-media outage into a total media outage. Add "message" here once the clients ship the
  # field — this list is the one-line switch.
  @conversation_anchored_purposes ["sealed_media"]

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
         {:ok, content_type} <- required_content_type(attrs, purpose),
         {:ok, size_bytes} <- required_size(attrs),
         {:ok, conversation_id} <- conversation_anchor(attrs, purpose) do
      media_id = generate_uuid()
      object_key = object_key(owner_user_id, media_id, filename)

      upload_attrs = %{
        "media_id" => media_id,
        "owner_user_id" => owner_user_id,
        "filename" => filename,
        "content_type" => content_type,
        "size_bytes" => size_bytes,
        "object_key" => object_key,
        "expires_at" => expires_at(),
        # A SERVER-SIDE uploader (e.g. UserService.UpiQr, "the server as media client") sets
        # "internal": the presigned PUT is then signed against the INTERNAL MinIO host so the put
        # travels the docker network, not the public Caddy/TLS edge a browser uses. The download
        # presign is unaffected — clients still get a public-host URL. See Storage.MinioAdapter.
        # NB: read the RAW attr (not optional_attr, which is binary-only) — a server-side caller sends
        # the boolean `true`, which survives the JSON round-trip over the internal HTTP API.
        "internal" => get_attr(attrs, "internal") in [true, "true"]
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

  # ---- S3 multipart upload (112) ------------------------------------------------------------------
  #
  # The Android client needs resumable, parallel, byte-progress uploads, which a single presigned PUT
  # cannot give it. These four functions are the minimal S3 multipart contract, and they deliberately
  # reuse the SINGLE-PUT path's validation and completion rather than running beside it:
  #
  #   * create runs the SAME required_attr / fetch_purpose / required_content_type / required_size
  #     checks and inserts the SAME media_assets row (status "created");
  #   * complete finishes the S3 upload and then calls the SAME complete_persisted/3 the single-PUT
  #     path uses — so ownership, tenancy, the measured-size cap and the response shape are identical
  #     by construction, not by imitation.
  #
  # NO MIGRATION. S3 owns the multipart state and hands back the `upload_id` that identifies it; the
  # media row already tracks created → ready. Persisting the upload_id would duplicate state S3 holds
  # authoritatively. The client therefore carries `media_id` alongside `upload_id`: the row lookup
  # (tenant + owner scoped) is the authorization, and S3 itself validates that the upload_id belongs
  # to that object key — a mismatched pair simply fails there.
  #
  # AN ABANDONED UPLOAD IS INERT. Parts live only inside S3's multipart staging area; no object exists
  # until complete succeeds, and the row stays "created", which can never presign a download or attach
  # to a message. Abort frees the staged parts; see the lifecycle note in the abort docstring.

  # S3's floor for every part except the last. Chosen server-side and returned so the client never has
  # to know the rule — and so we can raise it later without shipping a new client.
  @multipart_part_size 5 * 1024 * 1024
  @max_parts_per_request 1000
  # S3's hard ceiling on parts per upload.
  @max_part_number 10_000

  @doc """
  Begin a multipart upload. Same attrs as `create_upload/1`; `size_bytes` is the client's declared
  total and is capped here exactly as it is for a single PUT (the real size is re-checked at complete).

  → `{:ok, %{media_id, upload_id, object_key, part_size}}`.
  """
  def create_multipart_upload(attrs) do
    with {:ok, owner_user_id} <- required_attr(attrs, "owner_user_id"),
         {:ok, purpose} <- fetch_purpose(attrs),
         {:ok, filename} <- required_attr(attrs, "filename"),
         {:ok, content_type} <- required_content_type(attrs, purpose),
         {:ok, size_bytes} <- required_size(attrs),
         {:ok, conversation_id} <- conversation_anchor(attrs, purpose),
         :ok <- ensure_persistence() do
      media_id = generate_uuid()
      object_key = object_key(owner_user_id, media_id, filename)

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
           {:ok, %{upload_id: upload_id}} <-
             Storage.create_multipart_upload(%{"object_key" => object_key}) do
        {:ok,
         %{
           media_id: media_id,
           upload_id: upload_id,
           object_key: object_key,
           part_size: @multipart_part_size
         }}
      end
    end
  end

  @doc """
  Presigned PUT URLs for a window of part numbers — one round trip per window, so a client uploading
  in parallel does not pay a request per part.

  attrs: "media_id", "upload_id", "app_id", "owner_user_id", "part_numbers" (list of integers).
  → `{:ok, %{parts: [%{part_number, url}]}}`.
  """
  def presign_upload_parts(attrs) do
    with {:ok, upload_id} <- required_attr(attrs, "upload_id"),
         {:ok, numbers} <- validate_part_numbers(optional_list(attrs, "part_numbers")),
         {:ok, asset} <- owned_asset(attrs) do
      Storage.presign_upload_parts(%{
        "object_key" => asset.object_key,
        "upload_id" => upload_id,
        "part_numbers" => numbers
      })
    end
  end

  @doc """
  Assemble the uploaded parts, then run the SAME completion the single-PUT path runs — so the response
  shape, the measured-size cap and the ownership rules are identical.

  attrs: "media_id", "upload_id", "app_id", "owner_user_id", "parts" ([%{"part_number", "etag"}]).
  A missing or mismatched part makes S3 refuse to assemble → `:multipart_incomplete`, and the row is
  never marked ready. It is NEVER completed into a corrupt object.
  """
  def complete_multipart_upload(attrs) do
    with {:ok, upload_id} <- required_attr(attrs, "upload_id"),
         {:ok, parts} <- validate_parts(optional_list(attrs, "parts")),
         {:ok, asset} <- owned_asset(attrs),
         {:ok, _} <-
           Storage.complete_multipart_upload(%{
             "object_key" => asset.object_key,
             "upload_id" => upload_id,
             "parts" => parts
           }),
         {:ok, media_id} <- required_attr(attrs, "media_id"),
         {:ok, app_id} <- required_attr(attrs, "app_id"),
         {:ok, owner_user_id} <- required_attr(attrs, "owner_user_id") do
      # The object now exists; this HEADs it, enforces the cap on the MEASURED size, and flips the row
      # to ready — byte-for-byte the single-PUT completion.
      complete_persisted(media_id, app_id, owner_user_id)
    end
  end

  @doc """
  Abort an unfinished multipart upload: S3 discards the staged parts, and the row is marked deleted so
  its id can never be reused or presigned. Idempotent.

  OPS FOLLOW-UP (not implemented here): a client that dies without calling this leaves staged parts
  that S3 keeps until told otherwise. MinIO supports a lifecycle rule for exactly this —
  `mc ilm rule add --expire-delete-marker` style config, specifically
  `mc ilm rule add <alias>/chat-media --expiry-incomplete-multipart-upload-days 7` — which should be
  applied once to the bucket in deployment. Documented rather than done because it is a one-off ops
  action on the bucket, not application code.
  """
  def abort_multipart_upload(attrs) do
    with {:ok, upload_id} <- required_attr(attrs, "upload_id"),
         {:ok, asset} <- owned_asset(attrs) do
      _ =
        Storage.abort_multipart_upload(%{
          "object_key" => asset.object_key,
          "upload_id" => upload_id
        })

      asset
      |> MediaAsset.status_changeset("deleted", DateTime.utc_now())
      |> Repo.update()

      {:ok, %{aborted: true, media_id: asset.id}}
    end
  end

  # The row, scoped to the caller's tenant AND ownership — the same 404-not-403 posture as
  # complete_persisted: a foreign or cross-tenant media_id must not reveal that it exists.
  defp owned_asset(attrs) do
    with :ok <- ensure_persistence(),
         {:ok, media_id} <- required_attr(attrs, "media_id"),
         {:ok, app_id} <- required_attr(attrs, "app_id"),
         {:ok, owner_user_id} <- required_attr(attrs, "owner_user_id") do
      case Repo.get_by(MediaAsset, id: media_id, app_id: app_id) do
        %MediaAsset{owner_user_id: ^owner_user_id} = asset -> {:ok, asset}
        _ -> {:error, :not_found}
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  defp ensure_persistence do
    if media_persistence_enabled?(), do: :ok, else: {:error, :media_storage_unavailable}
  end

  defp optional_list(attrs, key) do
    case get_attr(attrs, key) do
      value when is_list(value) -> value
      _ -> nil
    end
  end

  # Part numbers must be a non-empty list of DISTINCT integers in 1..10000. Gaps are legal (a client
  # may request a later window first), duplicates and out-of-range values are not.
  defp validate_part_numbers(nil), do: {:error, :media_invalid}

  defp validate_part_numbers([]), do: {:error, :media_invalid}

  defp validate_part_numbers(numbers) when is_list(numbers) do
    normalized = Enum.map(numbers, &normalize_part_number/1)

    cond do
      Enum.any?(normalized, &is_nil/1) -> {:error, :media_invalid}
      length(normalized) > @max_parts_per_request -> {:error, :media_invalid}
      length(Enum.uniq(normalized)) != length(normalized) -> {:error, :media_invalid}
      true -> {:ok, normalized}
    end
  end

  defp normalize_part_number(value) when is_integer(value) do
    if value >= 1 and value <= @max_part_number, do: value, else: nil
  end

  defp normalize_part_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> normalize_part_number(number)
      _ -> nil
    end
  end

  defp normalize_part_number(_value), do: nil

  # Completion parts: every entry needs a valid part number AND a non-empty etag, and the numbers must
  # be distinct. S3 would reject a malformed set anyway; refusing here turns it into a 422 the client
  # can act on instead of an opaque storage error.
  defp validate_parts(nil), do: {:error, :media_invalid}

  defp validate_parts([]), do: {:error, :media_invalid}

  defp validate_parts(parts) when is_list(parts) do
    normalized =
      Enum.map(parts, fn part ->
        number = normalize_part_number(get_attr(part, "part_number"))
        etag = get_attr(part, "etag")

        if is_nil(number) or not (is_binary(etag) and etag != "") do
          nil
        else
          %{"part_number" => number, "etag" => etag}
        end
      end)

    numbers = Enum.map(normalized, fn part -> part && part["part_number"] end)

    cond do
      Enum.any?(normalized, &is_nil/1) -> {:error, :media_invalid}
      length(Enum.uniq(numbers)) != length(numbers) -> {:error, :media_invalid}
      true -> {:ok, normalized}
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
          download_persisted(media_id, app_id, expected_purpose(attrs))
        end
      else
        {:ok,
         placeholder_download_response(%{"media_id" => media_id, "expires_at" => expires_at()})}
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

  @doc """
  RECOVERY (client-assisted): attach a conversation to an asset that was created without one.

  Needed because ~33 sealed assets were minted anchorless before the create-side rule above existed, and
  the server CANNOT work out where they belong on its own: the sealed frame is opaque ciphertext, and
  `messages.media_id` is forced nil for sealed messages (message_store's oracle can never see them). Any
  server-side guess — same owner, nearby timestamp, only shared conversation — could bind an asset to the
  WRONG conversation, and a wrong anchor hands the file to people who were never sent it. That is strictly
  worse than the 404 it would fix, so no heuristic is used. The uploader's own client still holds the
  plaintext frame, so it is the only party that KNOWS the answer; this endpoint just lets it say so.

  Three constraints, all enforced here:

    * OWNER ONLY. Only the uploader may anchor. A recipient claim would let anyone who shares a
      conversation with the owner drag an unanchored asset into it, widening access to a file that was
      sent somewhere else entirely — the exact leak the no-heuristic rule exists to prevent.
    * UNANCHORED ONLY. An asset that already carries a conversation is immutable; re-anchoring would be a
      way to move a file between conversations after the fact.
    * IDEMPOTENT. Re-claiming to the SAME conversation succeeds, so a client can repair on every launch
      without tracking what it has already repaired.

  Membership in the claimed conversation is checked by the GATEWAY before this is called — the media
  service cannot reach conversation_service.
  """
  def anchor_asset(attrs) do
    with {:ok, media_id} <- required_attr(attrs, "media_id"),
         {:ok, app_id} <- required_attr(attrs, "app_id"),
         {:ok, owner_user_id} <- required_attr(attrs, "owner_user_id"),
         {:ok, conversation_id} <- required_attr(attrs, "conversation_id") do
      if media_persistence_enabled?() do
        do_anchor_asset(media_id, app_id, owner_user_id, conversation_id)
      else
        {:error, :not_found}
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  defp do_anchor_asset(media_id, app_id, owner_user_id, conversation_id) do
    case Repo.get_by(MediaAsset, id: media_id, app_id: app_id) do
      # Tenancy and ownership collapse to the same opaque :not_found as every other media authz failure —
      # a distinct "not yours" would confirm the id exists to anyone probing.
      nil ->
        {:error, :not_found}

      %MediaAsset{owner_user_id: ^owner_user_id} = asset ->
        case asset.conversation_id do
          nil ->
            persist_anchor(asset, conversation_id)

          "" ->
            persist_anchor(asset, conversation_id)

          ^conversation_id ->
            {:ok, %{media_id: media_id, conversation_id: conversation_id, anchored: false}}

          _other ->
            {:error, :media_already_anchored}
        end

      %MediaAsset{} ->
        {:error, :not_found}
    end
  end

  defp persist_anchor(%MediaAsset{} = asset, conversation_id) do
    case asset |> Ecto.Changeset.change(conversation_id: conversation_id) |> Repo.update() do
      {:ok, updated} ->
        {:ok, %{media_id: updated.id, conversation_id: conversation_id, anchored: true}}

      {:error, _changeset} ->
        {:error, :media_invalid}
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
          # STATUS presigns are SHORT-lived (300s vs the 900s default): status URLs are fetched at open
          # and never long-lived, and the short TTL bounds how long an issued URL outlives the post's
          # 24h expiry (the stated presign residual).
          override = if asset.purpose == "status", do: @status_url_expires_seconds, else: nil
          expires_at = expires_at(override)

          case Storage.get_download_url(%{
                 "object_key" => asset.object_key,
                 "media_id" => media_id,
                 "expires_at" => expires_at,
                 "url_expires_seconds" => override
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

  # The expected-purpose filter, read WITHOUT optional_attr/2 on purpose: that helper answers nil for
  # anything non-binary, so a list would have silently become "no check at all" — turning an assertion
  # into a bypass at the one call site that most needs it.
  defp expected_purpose(attrs) do
    case get_attr(attrs, "purpose") do
      [_ | _] = purposes -> Enum.filter(purposes, &(is_binary(&1) and &1 != ""))
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp purpose_ok?(_asset, nil), do: true
  defp purpose_ok?(_asset, []), do: true

  # A LIST admits several purposes while keeping the assertion — needed since 113, where a message
  # attachment may legitimately be either "message" or the server-generated "user_asset" (a /qr send).
  # Still an assertion, not a bypass: anything outside the list is refused, so a poisoned
  # avatar_media_id can no more presign an attachment than before.
  defp purpose_ok?(%MediaAsset{purpose: purpose}, expected) when is_list(expected),
    do: purpose in expected

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
  PURGE an asset's bytes (the status sweep + owner-delete path): delete the stored object (best-effort)
  and mark the row deleted so it can never presign again. Row kept as a tombstone (ids stay dead, not
  reusable). Missing asset → {:ok, %{purged: false}} — the sweep must be idempotent.
  """
  def purge_asset(attrs) do
    with {:ok, media_id} <- required_attr(attrs, "media_id"),
         {:ok, app_id} <- required_attr(attrs, "app_id") do
      if media_persistence_enabled?() do
        case Repo.get_by(MediaAsset, id: media_id, app_id: app_id) do
          nil ->
            {:ok, %{purged: false}}

          %MediaAsset{} = asset ->
            _ = Storage.delete_object(%{"object_key" => asset.object_key})

            asset
            |> MediaAsset.status_changeset("deleted", DateTime.utc_now())
            |> Repo.update()

            {:ok, %{purged: true}}
        end
      else
        {:ok, %{purged: false}}
      end
    end
  rescue
    Ecto.Query.CastError -> {:ok, %{purged: false}}
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
      nil ->
        {:ok, "message"}

      "" ->
        {:ok, "message"}

      # "status" was authorized (download presign + the status authz arm, e4189ce) MONTHS before it
      # was uploadable — this list was never told the purpose existed, so photo/video status 400'd at
      # create while every status test fabricated media ids. Adding a purpose ANYWHERE downstream
      # (authz, presign TTL, gateway assertion) requires adding it here AND to the upload-path
      # purpose test in MediaService.MediaTest, which now enumerates this list.
      # sealed_media (110): an E2EE attachment — ciphertext bytes, stored + served opaquely (the
      # media service never processes any purpose's bytes). Download ACL = message media.
      # user_asset (113): server-generated, user-owned, no conversation (the UPI QR). INTERNAL ONLY —
      # deliberately absent from the gateway's @upload_purposes and v1's @purposes, so no client can
      # ask for it; only in-process callers like UserService.UpiQr reach this list.
      purpose
      when purpose in [
             "message",
             "user_avatar",
             "group_avatar",
             "status",
             "sealed_media",
             "user_asset"
           ] ->
        {:ok, purpose}

      _ ->
        {:error, :media_invalid}
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

  # sealed_media (110): the uploaded bytes are CIPHERTEXT; the declared type is the opaque
  # application/octet-stream and the real mime rides INSIDE the sealed frame — so the plaintext
  # content-type whitelist does not apply. Every other purpose keeps the strict whitelist.
  defp required_content_type(attrs, "sealed_media") do
    with {:ok, content_type} <- required_attr(attrs, "content_type"),
         base_type = base_content_type(content_type),
         true <- base_type == "application/octet-stream" do
      {:ok, base_type}
    else
      _ -> {:error, :media_invalid}
    end
  end

  defp required_content_type(attrs, _purpose) do
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

  # The anchor rule, applied identically by BOTH create paths (single PUT and multipart) — one
  # function, so the two can never drift the way the upload-side purpose whitelist once did.
  defp conversation_anchor(attrs, purpose) do
    conversation_id = optional_attr(attrs, "conversation_id")

    cond do
      is_binary(conversation_id) and conversation_id != "" ->
        {:ok, conversation_id}

      purpose in @conversation_anchored_purposes ->
        {:error, :media_conversation_required}

      true ->
        {:ok, nil}
    end
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

  defp expires_at(override \\ nil) do
    expires_in_seconds =
      override ||
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
