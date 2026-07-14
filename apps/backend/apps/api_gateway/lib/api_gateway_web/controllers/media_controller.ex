defmodule ApiGatewayWeb.MediaController do
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

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
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :media_unavailable} -> service_unavailable(conn)
      {:error, :media_too_large} -> too_large(conn)
      {:error, :conversation_unavailable} -> service_unavailable(conn)
      # A non-participant (message) → 404, no existence reveal. A member-but-not-admin (group_avatar) →
      # 403, mirroring the existing group-profile behaviour (conversation_service ensure_owner → 403).
      {:error, :not_a_member} -> not_found(conn)
      {:error, :not_group_admin} -> forbidden(conn)
      _ -> invalid_request(conn)
    end
  end

  # Enforce the upload's authorization by purpose. Only checks when a conversation_id is supplied (the
  # current frontend supplies none → no check this slice; Phase 5 sends it → enforcement activates).
  defp authorize_upload(_purpose, conversation_id, _user_id)
       when not is_binary(conversation_id) or conversation_id == "",
       do: :ok

  defp authorize_upload("message", conversation_id, user_id),
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

  # group_avatar: reuse the ensure_owner predicate (role ∈ owner/admin). A non-member and a
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

  defp upload_purpose(params) do
    case params["purpose"] do
      purpose when purpose in ["message", "user_avatar", "group_avatar"] -> purpose
      _ -> "message"
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
           SharedInfra.MediaClient.get_asset(%{"media_id" => media_id, "app_id" => session.app_id}),
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
    do: ErrorResponse.forbidden(conn, "media.forbidden", "Not allowed to upload for this conversation")

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
