defmodule ApiGatewayWeb.MediaController do
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  # UPLOAD CREATION LIMITS — two windows, per user.
  #
  # Each create issues a presigned PUT, and the bytes go straight to storage without passing through
  # this app. So the thing being limited is HOW MANY presigned URLs a user can obtain: unbounded
  # before this, which meant one session in a loop could fill MinIO, and a full disk takes the
  # platform down for everyone rather than only the abuser.
  #
  # DAILY (500) is the one that bounds accumulation; PER-MINUTE (60) mostly stops a runaway client
  # (a retry loop with no backoff) from spending the daily budget in seconds.
  #
  # 60/min, not the 30/min the policy doc suggested. A multi-image send creates one upload PER image,
  # and the batch cap is 10 — MediaConstraints.MAX_BATCH_ITEMS, exway-android
  # core/media/MediaConstraints.kt. So 60/min clears SIX full batches, comfortably above real usage.
  # (The web client is strictly one file at a time; the multi-select path is Android's.)
  #
  # If MAX_BATCH_ITEMS ever rises, re-check this: the floor that matters is one batch per request
  # round, and 60 stops being generous somewhere above a cap of ~20.
  @upload_burst_limit 60
  @upload_burst_window_seconds 60
  @upload_daily_limit 500
  @upload_daily_window_seconds 86_400

  def create_upload(conn, params) do
    if media_persistence_enabled?() do
      create_upload_with_session(conn, params)
    else
      create_placeholder_upload(conn, params)
    end
  end

  defp create_placeholder_upload(conn, params) do
    with {:ok, response} <-
           params
           |> Map.put("owner_user_id", "user_placeholder")
           |> SharedInfra.MediaClient.create_upload() do
      conn
      |> put_status(:created)
      |> json(response)
    else
      _ -> invalid_request(conn)
    end
  end

  defp create_upload_with_session(conn, params) do
    purpose = upload_purpose(params)
    conversation_id = params["conversation_id"]

    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         :ok <- upload_rate_limit(session.user_id),
         # Membership (message) / owner-admin (group_avatar) is enforced HERE — the gateway can reach
         # conversation_service; the media service can't. Only enforced when a conversation_id is present
         # (the current frontend sends none; Phase 5 will) — see the module note.
         :ok <- authorize_upload(purpose, conversation_id, session.user_id),
         {:ok, response} <-
           params
           |> Map.put("owner_user_id", session.user_id)
           |> Map.put("app_id", session.app_id)
           |> Map.put("purpose", purpose)
           |> SharedInfra.MediaClient.create_upload() do
      conn
      |> put_status(:created)
      |> json(response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
      {:error, :rate_limited, retry_after_seconds} -> rate_limited(conn, retry_after_seconds)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :media_unavailable} -> service_unavailable(conn)
      {:error, :media_too_large} -> too_large(conn)
      {:error, :conversation_unavailable} -> service_unavailable(conn)
      # A non-participant (message) → 404, no existence reveal. A member-but-not-admin (group_avatar) →
      # 403, mirroring the existing group-profile behaviour (conversation_service ensure_owner_or_admin → 403).
      {:error, :not_a_member} -> not_found(conn)
      {:error, :not_group_admin} -> forbidden(conn)
      _ -> invalid_request(conn)
    end
  end

  # FAIL-OPEN, per the policy rule: losing an upload costs a user their photo, and a limiter outage
  # must not do that. Argued the other way and rejected: failing CLOSED would only be worth the
  # breakage if this limiter were tight disk protection, and it is not — at the 100 MB per-object cap
  # a full daily budget is still ~50 GB per account (see RATE_LIMIT_POLICY.md, byte-quota follow-up).
  # It converts "unbounded" into "bounded", which is the win; the disk is properly defended by a byte
  # quota and capacity alerting, not by refusing uploads whenever Redis blinks.
  #
  # The DAILY window is checked FIRST so the limit that actually bounds accumulation is the one that
  # gets charged when both would trip, and so its Retry-After (the long one) is what the client sees.
  defp upload_rate_limit(user_id) do
    with :ok <-
           check_window(
             "media_upload_day:",
             user_id,
             @upload_daily_limit,
             @upload_daily_window_seconds
           ) do
      check_window("media_upload:", user_id, @upload_burst_limit, @upload_burst_window_seconds)
    end
  end

  defp check_window(prefix, user_id, limit, window_seconds) do
    case SharedInfra.RateLimiter.check_rate(%{
           "key" => prefix <> user_id,
           "limit" => limit,
           "window_seconds" => window_seconds
         }) do
      :ok -> :ok
      {:error, :rate_limited, _retry} = limited -> limited
      _ -> :ok
    end
  end

  defp rate_limited(conn, retry_after_seconds) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds))
    |> ErrorResponse.rate_limited("media.rate_limited")
  end

  # ---- S3 multipart upload (112) ------------------------------------------------------------------
  #
  # Resumable/parallel uploads for the mobile clients. Every one of these actions runs through the
  # SAME session resolution, the SAME `upload_purpose/1` whitelist and the SAME `authorize_upload/3`
  # as the single-PUT `create_upload/2` above — deliberately not a parallel authorization path, which
  # is exactly how "sealed_media" was silently coerced to "message" before d4af319.

  @doc """
  POST /api/v1/media/upload/multipart — begin a multipart upload.
  → 201 {media_id, upload_id, object_key, part_size}
  """
  def create_multipart(conn, params) do
    if media_persistence_enabled?() do
      purpose = upload_purpose(params)
      conversation_id = params["conversation_id"]

      with {:ok, session} <- session(conn),
           :ok <- upload_rate_limit(session.user_id),
           :ok <- authorize_upload(purpose, conversation_id, session.user_id),
           {:ok, response} <-
             params
             |> Map.put("owner_user_id", session.user_id)
             |> Map.put("app_id", session.app_id)
             |> Map.put("purpose", purpose)
             |> SharedInfra.MediaClient.create_multipart_upload() do
        conn |> put_status(:created) |> json(response)
      else
        error -> multipart_error(conn, error)
      end
    else
      invalid_request(conn)
    end
  end

  @doc """
  POST /api/v1/media/upload/multipart/:upload_id/parts — presigned PUT URLs for a window of parts.
  Body: {media_id, part_numbers: [int]} → 200 {parts: [{part_number, url}]}
  """
  def multipart_parts(conn, %{"upload_id" => upload_id} = params) do
    with {:ok, session} <- session(conn),
         {:ok, response} <-
           params
           |> Map.put("upload_id", upload_id)
           |> Map.put("owner_user_id", session.user_id)
           |> Map.put("app_id", session.app_id)
           |> SharedInfra.MediaClient.presign_upload_parts() do
      json(conn, response)
    else
      error -> multipart_error(conn, error)
    end
  end

  def multipart_parts(conn, _params), do: invalid_request(conn)

  @doc """
  POST /api/v1/media/upload/multipart/:upload_id/complete — assemble the object.
  Body: {media_id, parts: [{part_number, etag}]} → the SAME response as complete_upload, so clients
  converge on one post-upload path.
  """
  def multipart_complete(conn, %{"upload_id" => upload_id} = params) do
    with {:ok, session} <- session(conn),
         {:ok, response} <-
           params
           |> Map.put("upload_id", upload_id)
           |> Map.put("owner_user_id", session.user_id)
           |> Map.put("app_id", session.app_id)
           |> SharedInfra.MediaClient.complete_multipart_upload() do
      json(conn, response)
    else
      error -> multipart_error(conn, error)
    end
  end

  def multipart_complete(conn, _params), do: invalid_request(conn)

  @doc """
  DELETE /api/v1/media/upload/multipart/:upload_id — abort and free the staged parts.
  Body/query: media_id → 200 {aborted: true, media_id}.
  """
  def multipart_abort(conn, %{"upload_id" => upload_id} = params) do
    with {:ok, session} <- session(conn),
         {:ok, response} <-
           params
           |> Map.put("upload_id", upload_id)
           |> Map.put("owner_user_id", session.user_id)
           |> Map.put("app_id", session.app_id)
           |> SharedInfra.MediaClient.abort_multipart_upload() do
      json(conn, response)
    else
      error -> multipart_error(conn, error)
    end
  end

  def multipart_abort(conn, _params), do: invalid_request(conn)

  defp session(conn) do
    with {:ok, authorization} <- authorization_header(conn) do
      SharedInfra.AuthClient.current_session(%{"authorization" => authorization})
    end
  end

  # Same mapping as the single-PUT path, plus the two multipart-specific outcomes.
  defp multipart_error(conn, error) do
    case error do
      {:error, :session_invalid} ->
        unauthorized(conn)

      {:error, :rate_limited, retry_after_seconds} ->
        rate_limited(conn, retry_after_seconds)

      {:error, :auth_unavailable} ->
        service_unavailable(conn)

      {:error, :media_unavailable} ->
        service_unavailable(conn)

      {:error, :media_storage_unavailable} ->
        service_unavailable(conn)

      {:error, :media_too_large} ->
        too_large(conn)

      {:error, :conversation_unavailable} ->
        service_unavailable(conn)

      # A non-participant, a foreign owner, or a cross-tenant media_id all read the same: 404, no
      # existence reveal — identical posture to complete_upload.
      {:error, :not_a_member} ->
        not_found(conn)

      {:error, :not_found} ->
        not_found(conn)

      {:error, :not_group_admin} ->
        forbidden(conn)

      # S3 refused to assemble (a missing or mismatched part). The object does NOT exist and the row
      # was never marked ready — the client can re-upload the missing part and complete again.
      {:error, :multipart_incomplete} ->
        ErrorResponse.unprocessable_entity(
          conn,
          "media.multipart_incomplete",
          "Some parts are missing or do not match; re-upload them and complete again"
        )

      # Bad part numbers / etags — actionable, so 422 rather than a flat 400.
      {:error, :media_invalid} ->
        ErrorResponse.unprocessable_entity(
          conn,
          "media.invalid_parts",
          "part_numbers must be distinct integers in 1..10000, and each part needs an etag"
        )

      _ ->
        invalid_request(conn)
    end
  end

  # Enforce the upload's authorization by purpose. Only checks when a conversation_id is supplied (the
  # current frontend supplies none → no check this slice; Phase 5 sends it → enforcement activates).
  defp authorize_upload(_purpose, conversation_id, _user_id)
       when not is_binary(conversation_id) or conversation_id == "",
       do: :ok

  defp authorize_upload("message", conversation_id, user_id),
    do: membership(conversation_id, user_id)

  # sealed_media (110): same conversation-membership scope as a normal message attachment.
  defp authorize_upload("sealed_media", conversation_id, user_id),
    do: membership(conversation_id, user_id)

  defp authorize_upload("group_avatar", conversation_id, user_id),
    do: group_admin(conversation_id, user_id)

  # user_avatar (or any other purpose) ignores conversation_id — no conversation to scope to.
  defp authorize_upload(_purpose, _conversation_id, _user_id), do: :ok

  # The gallery's predicate: get_conversation with the caller's user_id runs fetch_active_participant.
  defp membership(conversation_id, user_id) do
    case SharedInfra.ConversationClient.get_conversation(%{
           "conversation_id" => conversation_id,
           "user_id" => user_id
         }) do
      {:ok, _conversation} -> :ok
      {:error, :conversation_unavailable} -> {:error, :conversation_unavailable}
      _ -> {:error, :not_a_member}
    end
  end

  # group_avatar: reuse the ensure_owner_or_admin predicate (role ∈ owner/admin). A non-member and a
  # member-but-not-admin both fail as :not_group_admin → 403 (matches conversation_service's group-profile).
  defp group_admin(conversation_id, user_id) do
    case SharedInfra.ConversationClient.get_conversation(%{
           "conversation_id" => conversation_id,
           "user_id" => user_id
         }) do
      {:ok, conversation} ->
        if participant_role(conversation, user_id) in ["owner", "admin"],
          do: :ok,
          else: {:error, :not_group_admin}

      {:error, :conversation_unavailable} ->
        {:error, :conversation_unavailable}

      _ ->
        {:error, :not_group_admin}
    end
  end

  defp participant_role(conversation, user_id) do
    (Map.get(conversation, :participants) || Map.get(conversation, "participants") || [])
    |> Enum.find(fn participant ->
      (Map.get(participant, :user_id) || Map.get(participant, "user_id")) == user_id
    end)
    |> case do
      nil -> nil
      participant -> Map.get(participant, :role) || Map.get(participant, "role")
    end
  end

  # The purpose passthrough. An unrecognised value coerces to "message" rather than 400-ing, so a
  # client sending nothing (or junk) still gets the ordinary attachment path.
  #
  # THAT COERCION IS ALSO A TRAP: a purpose the media service supports but that is MISSING here is not
  # rejected, it is silently rewritten — and then fails downstream against the wrong purpose's rules.
  # "sealed_media" (110) hit exactly that: it became "message", whose content-type allow-list refuses
  # the application/octet-stream that MediaService.Media REQUIRES for sealed media, so every E2EE
  # attachment 400'd as media.invalid_request. Adding a purpose to the media service means adding it
  # here too (and to authorize_upload/3 above, which already had its sealed_media clause).
  defp upload_purpose(params) do
    case params["purpose"] do
      purpose
      when purpose in ["message", "user_avatar", "group_avatar", "status", "sealed_media"] ->
        purpose

      _ ->
        "message"
    end
  end

  def complete_upload(conn, %{"media_id" => media_id} = params) do
    if media_persistence_enabled?() do
      complete_upload_with_session(conn, media_id, params)
    else
      complete_placeholder_upload(conn, media_id, params)
    end
  end

  defp complete_placeholder_upload(conn, media_id, params) do
    with {:ok, response} <-
           params
           |> Map.put("media_id", media_id)
           |> Map.put("owner_user_id", "user_placeholder")
           |> SharedInfra.MediaClient.complete_upload() do
      json(conn, response)
    else
      _ -> invalid_request(conn)
    end
  end

  # Completion takes media_id + the caller + tenant ONLY — never the client's object_key. The media
  # service resolves the row (scoped to app_id) and verifies the caller OWNS it; a foreign / missing /
  # cross-tenant media_id → 404. (`params` is intentionally dropped so a client object_key can't ride along.)
  defp complete_upload_with_session(conn, media_id, _params) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, response} <-
           SharedInfra.MediaClient.complete_upload(%{
             "media_id" => media_id,
             "owner_user_id" => session.user_id,
             "app_id" => session.app_id
           }) do
      json(conn, response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :media_unavailable} -> service_unavailable(conn)
      {:error, :not_found} -> not_found(conn)
      # REAL uploaded bytes over the cap (HEAD-verified at complete). Object deleted, asset NOT ready.
      # 413 — the same mapping create_upload already uses for an over-cap CLAIM.
      {:error, :media_too_large} -> too_large(conn)
      # The presigned PUT never happened → nothing to complete.
      {:error, :upload_not_found} -> not_found(conn)
      # Unverifiable (storage unreachable) → FAIL CLOSED, never mark ready. Transient: retry complete.
      {:error, :verify_failed} -> service_unavailable(conn)
      _ -> invalid_request(conn)
    end
  end

  def download(conn, %{"media_id" => media_id} = params) do
    if media_persistence_enabled?() do
      download_with_session(conn, media_id, params)
    else
      placeholder_download(conn, media_id, params)
    end
  end

  defp placeholder_download(conn, media_id, params) do
    with {:ok, response} <-
           params
           |> Map.put("media_id", media_id)
           |> Map.put("owner_user_id", "user_placeholder")
           |> SharedInfra.MediaClient.get_download_url() do
      json(conn, response)
    else
      _ -> invalid_request(conn)
    end
  end

  # AUTHORIZE, then presign. The object_key is resolved server-side FROM THE ROW (never the client's), so
  # `params` (which may still carry a client object_key until Phase 5) is intentionally ignored. Every
  # authorization/lookup failure collapses to 404 — no existence reveal, never 403, no distinction between
  # "doesn't exist", "wrong tenant", and "not a member".
  defp download_with_session(conn, media_id, _params) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, asset} <-
           SharedInfra.MediaClient.get_asset(%{
             "media_id" => media_id,
             "app_id" => session.app_id
           }),
         :ok <- ApiGatewayWeb.MediaAuthz.authorize_download(media_id, asset, session.user_id),
         {:ok, response} <-
           SharedInfra.MediaClient.get_download_url(%{
             "media_id" => media_id,
             "app_id" => session.app_id
           }) do
      json(conn, response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :media_unavailable} -> service_unavailable(conn)
      {:error, :conversation_unavailable} -> service_unavailable(conn)
      # not_found (unknown / cross-tenant asset), not_a_member, or any other failure → opaque 404.
      _ -> not_found(conn)
    end
  end

  defp invalid_request(conn), do: ErrorResponse.invalid_request(conn, "media.invalid_request")

  defp too_large(conn),
    do:
      ErrorResponse.payload_too_large(
        conn,
        "media.too_large",
        "File is too large to upload."
      )

  defp service_unavailable(conn), do: ErrorResponse.service_unavailable(conn, "media.unavailable")

  defp unauthorized(conn),
    do: ErrorResponse.unauthorized(conn, "media.unauthorized", "Missing or invalid access token")

  defp not_found(conn), do: ErrorResponse.not_found(conn, "media.not_found", "Not found")

  defp forbidden(conn),
    do:
      ErrorResponse.forbidden(
        conn,
        "media.forbidden",
        "Not allowed to upload for this conversation"
      )

  defp authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> _token = authorization] -> {:ok, authorization}
      _ -> {:error, :session_invalid}
    end
  end

  defp media_persistence_enabled? do
    Application.get_env(:media_service, :media_persistence, false) ||
      System.get_env("MEDIA_DB_BACKED") in ["true", "1", "yes"]
  end
end
