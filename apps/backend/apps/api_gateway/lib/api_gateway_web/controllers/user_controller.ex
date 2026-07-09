defmodule ApiGatewayWeb.UserController do
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  @allowed_update_fields ["display_name", "bio", "avatar_media_id", "avatar_object_key"]

  def me(conn, params) do
    if user_profile_persistence_enabled?() do
      current_profile_from_db(conn, params)
    else
      placeholder_current_profile(conn, params)
    end
  end

  def update_me(conn, params) do
    if user_profile_persistence_enabled?() do
      update_current_profile_from_db(conn, params)
    else
      placeholder_update_current_profile(conn, params)
    end
  end

  def profile(conn, %{"user_id" => user_id} = params) do
    with {:ok, response} <-
           SharedInfra.UserClient.get_public_profile(Map.put(params, "user_id", user_id)) do
      json(conn, with_avatar_url(response))
    else
      {:error, :profile_invalid} -> invalid_request(conn)
      {:error, :user_unavailable} -> service_unavailable(conn)
    end
  end

  @doc """
  PUBLIC avatar proxy — a STABLE, unauthenticated URL that 302-redirects to a freshly-presigned avatar
  download. Exists so a web-push notification ICON can point at a permanent URL: the presign happens
  per-request, so the URL itself never expires. Serves ONLY the avatar image (302 to MinIO), nothing
  else; no avatar / any error → 404 so the client falls back to the app icon. Must be public because
  the OS/service-worker fetches notification icons with no session.

  Privacy note: this makes avatars fetchable by user id without auth (already visible to any
  authenticated peer via /profile; standard for chat notification icons). `profile_photo_visibility`
  gating is the same tracked follow-up noted on `with_avatar_url`.
  """
  def avatar(conn, %{"user_id" => user_id}) do
    with {:ok, profile} <- SharedInfra.UserClient.get_public_profile(%{"user_id" => user_id}),
         %{avatar_url: url} when is_binary(url) <- with_avatar_url(profile) do
      conn
      |> put_resp_header("cache-control", "private, max-age=60")
      |> redirect(external: url)
    else
      _ -> conn |> put_status(:not_found) |> json(%{error: %{code: "user.no_avatar"}})
    end
  end

  @doc """
  DIRECT-PEER contact info (phone number) — the ONLY place a user's phone is exposed to another user.

  Privacy scope, verified SERVER-SIDE before any phone read:
    1. session → the caller;
    2. `ConversationClient.get_conversation(conversation_id, user_id: CALLER)` — this call itself
       403s unless the CALLER is an ACTIVE participant of the conversation (fetch_active_participant
       in the conversation service), so membership can't be spoofed client-side;
    3. the conversation must be type "direct", and :user_id must be the OTHER active participant.
  Only then is the phone joined from auth. The general public profile NEVER includes a phone, and
  group members / non-peers get 403 here.
  """
  def peer_contact(conn, %{"user_id" => target_user_id, "conversation_id" => conversation_id})
      when is_binary(conversation_id) and conversation_id != "" do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, conversation} <-
           SharedInfra.ConversationClient.get_conversation(%{
             "conversation_id" => conversation_id,
             "user_id" => session.user_id
           }),
         :ok <- verify_direct_peer(conversation, session.user_id, target_user_id),
         {:ok, contact} <- SharedInfra.AuthClient.get_user_phone(%{"user_id" => target_user_id}) do
      json(conn, %{
        user_id: target_user_id,
        phone_number: Map.get(contact, :phone_number) || Map.get(contact, "phone_number")
      })
    else
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :conversation_unavailable} -> service_unavailable(conn)
      {:error, :not_direct_peer} -> not_direct_peer(conn)
      {:error, :not_found} -> phone_not_found(conn)
      # Conversation lookup rejections (non-member, unknown id) collapse to the same 403.
      _ -> not_direct_peer(conn)
    end
  end

  def peer_contact(conn, _params), do: invalid_request(conn)

  # Direct type + the target is the OTHER active participant (never the caller, never a group member).
  defp verify_direct_peer(conversation, caller_user_id, target_user_id) do
    type = Map.get(conversation, :type) || Map.get(conversation, "type")
    participants = Map.get(conversation, :participants) || Map.get(conversation, "participants") || []

    participant_ids =
      Enum.map(participants, fn p -> Map.get(p, :user_id) || Map.get(p, "user_id") end)

    if type == "direct" and target_user_id != caller_user_id and
         caller_user_id in participant_ids and target_user_id in participant_ids do
      :ok
    else
      {:error, :not_direct_peer}
    end
  end

  defp not_direct_peer(conn),
    do:
      ErrorResponse.forbidden(
        conn,
        "user.not_direct_peer",
        "Contact info is only visible to a direct-chat peer"
      )

  @doc """
  Resolve a phone number (E.164) → a public profile, for starting a WhatsApp-style direct chat.

  Unlike `profile/2`, this is SESSION-GATED: only a logged-in caller may probe whether a number is
  registered (limits enumeration; see the rate-limit follow-up note). It returns the SAME shape as
  `profile/2` — {user_id, display_name, avatar_url} — so the client reuses its found-participant card.
  An unknown/inactive number → 404; your own number → 409 (can't DM yourself). A resolved-but-not-yet-
  onboarded user still succeeds (display_name null), so the chat can start before they set a name.
  """
  def by_phone(conn, %{"phone" => phone}) when is_binary(phone) and phone != "" do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, %{user_id: user_id}} <-
           SharedInfra.AuthClient.lookup_user_by_phone(%{"phone_number" => phone}),
         :ok <- reject_self(session.user_id, user_id),
         {:ok, response} <-
           SharedInfra.UserClient.get_public_profile(%{"user_id" => user_id}) do
      json(conn, with_avatar_url(response))
    else
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :user_unavailable} -> service_unavailable(conn)
      {:error, :not_found} -> phone_not_found(conn)
      {:error, :self_lookup} -> self_lookup(conn)
      # The number resolved to a user but their profile row is malformed — treat as not found rather
      # than leaking a 400 for a lookup whose phone was perfectly valid.
      {:error, :profile_invalid} -> phone_not_found(conn)
      _ -> invalid_request(conn)
    end
  end

  def by_phone(conn, _params), do: invalid_request(conn)

  defp reject_self(caller_user_id, found_user_id) do
    if caller_user_id == found_user_id, do: {:error, :self_lookup}, else: :ok
  end

  defp placeholder_current_profile(conn, params) do
    with {:ok, response} <- SharedInfra.UserClient.get_current_profile(params) do
      json(conn, with_avatar_url(response))
    end
  end

  defp current_profile_from_db(conn, _params) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, response} <-
           SharedInfra.UserClient.get_current_profile(%{"user_id" => session.user_id}) do
      json(conn, with_avatar_url(response))
    else
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :user_unavailable} -> service_unavailable(conn)
      {:error, :profile_invalid} -> session_invalid(conn)
      _ -> session_invalid(conn)
    end
  end

  defp placeholder_update_current_profile(conn, params) do
    with :ok <- validate_update_payload(params),
         {:ok, response} <- SharedInfra.UserClient.update_current_profile(params) do
      json(conn, with_avatar_url(response))
    else
      _ -> invalid_request(conn)
    end
  end

  defp update_current_profile_from_db(conn, params) do
    with :ok <- validate_update_payload(params),
         {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, response} <-
           SharedInfra.UserClient.update_current_profile(
             Map.put(params, "user_id", session.user_id)
           ) do
      json(conn, with_avatar_url(response))
    else
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :user_unavailable} -> service_unavailable(conn)
      {:error, :profile_invalid} -> invalid_request(conn)
      _ -> invalid_request(conn)
    end
  end

  # Enrich a profile map with a ready-to-use signed `avatar_url`. The profile stores `avatar_media_id`
  # + `avatar_object_key`; presigning a download URL needs the object_key (a viewer can't reconstruct
  # another user's key), so the gateway resolves it via the media client and attaches `avatar_url`.
  # Best-effort: any missing field or media error just leaves the profile unchanged (no avatar_url).
  # NOTE: not yet gated by `profile_photo_visibility` (the privacy module is a placeholder today) —
  # avatar visibility gating is a tracked follow-up.
  defp with_avatar_url(profile) when is_map(profile) do
    media_id = Map.get(profile, :avatar_media_id)
    app_id = Map.get(profile, :app_id)

    result =
      if is_binary(media_id) and is_binary(app_id) do
        # Presign scoped to the PROFILE's app (the /avatar route is unauthenticated → no caller app_id).
        # object_key is resolved server-side from the row; the "user_avatar" purpose assertion refuses to
        # presign a non-avatar asset (so a poisoned avatar_media_id can't presign a message attachment). On
        # any media error, leave the profile unchanged (fail-open) so a glitch never wipes a valid avatar.
        with {:ok, download} <-
               SharedInfra.MediaClient.get_download_url(%{
                 "media_id" => media_id,
                 "app_id" => app_id,
                 "purpose" => "user_avatar"
               }),
             url when is_binary(url) <- Map.get(download, :download_url) do
          Map.put(profile, :avatar_url, url)
        else
          _ -> profile
        end
      else
        # No avatar (never set, or just cleared) → avatar_url: nil EXPLICITLY so clients drop any stale URL.
        Map.put(profile, :avatar_url, nil)
      end

    # app_id is an INTERNAL presign input — never leak the tenant id to the client.
    Map.delete(result, :app_id)
  end

  defp with_avatar_url(other), do: other

  defp authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, "Bearer " <> token}
      _ -> {:error, :session_invalid}
    end
  end

  defp validate_update_payload(params) do
    keys = Enum.map(Map.keys(params), &to_string/1)

    if keys != [] and Enum.all?(keys, &(&1 in @allowed_update_fields)) do
      :ok
    else
      {:error, :invalid_request}
    end
  end

  defp user_profile_persistence_enabled? do
    Application.get_env(:user_service, :user_profile_persistence, false) ||
      System.get_env("USER_PROFILE_DB_BACKED") == "true"
  end

  defp invalid_request(conn), do: ErrorResponse.invalid_request(conn, "user.invalid_request")

  defp service_unavailable(conn), do: ErrorResponse.service_unavailable(conn, "user.unavailable")

  defp phone_not_found(conn),
    do: ErrorResponse.not_found(conn, "user.phone_not_found", "No account uses this number")

  defp self_lookup(conn),
    do: ErrorResponse.conflict(conn, "user.self_lookup", "You can't start a chat with yourself")

  defp session_invalid(conn),
    do: ErrorResponse.unauthorized(conn, "auth.session_invalid", "Session token is invalid")
end
