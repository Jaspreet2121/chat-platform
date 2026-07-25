defmodule ApiGatewayWeb.UserController do
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  # avatar_object_key is NO LONGER accepted — the server resolves object_key from the media_assets row
  # (bee9562). It is tolerated in the body but stripped + ignored (never persisted). avatar_media_id is
  # accepted but VALIDATED for ownership before it is stored (see validate_avatar_media_id/2).
  @allowed_update_fields ["display_name", "bio", "avatar_media_id"]
  @ignored_update_fields ["avatar_object_key"]

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

  # Public profile — FULLY authenticated + app-scoped. The target must be in the CALLER's app; a
  # cross-tenant (or unknown/no-profile) user_id → 404 with a generic body (no existence reveal). Profile
  # DATA and the avatar IMAGE are separate concerns: this returns data; the avatar image has its own route.
  def profile(conn, %{"user_id" => user_id}) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, response} <-
           SharedInfra.UserClient.get_public_profile(%{
             "user_id" => user_id,
             "app_id" => session_app(session)
           }) do
      json(conn, present_profile(session.user_id, user_id, response))
    else
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :user_unavailable} -> service_unavailable(conn)
      # Cross-tenant / unknown / no-profile → 404, nothing revealed.
      _ -> profile_not_found(conn)
    end
  end

  @doc """
  Avatar image → 302 to a freshly-presigned MinIO URL. AUTHENTICATED + app-scoped: the target must be in
  the caller's app (cross-tenant → 404). This is the normal in-app path (e.g. rendering a peer's avatar).
  A missing/absent avatar → 404.

  The ONLY unauthenticated way to fetch an avatar image is `push_avatar/2` below (`/api/v1/push/avatar/:token`),
  which requires a narrow HMAC capability token — see SharedInfra.AvatarToken. Nothing else is public.
  """
  def avatar(conn, %{"user_id" => user_id}) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, url} <- presign_avatar(user_id, session_app(session)) do
      redirect_avatar(conn, url)
    else
      {:error, :session_invalid} -> session_invalid(conn)
      # Cross-tenant / no avatar / any media error → 404 (SW falls back to the app icon).
      _ -> no_avatar(conn)
    end
  end

  @doc """
  UNAUTHENTICATED avatar image for web-push notification icons — the ONLY public avatar path. Verifies a
  narrow HMAC capability token (SharedInfra.AvatarToken) bound to `(user_id, app_id, kind: avatar)`, then
  302s to a presigned avatar for exactly that user, in that app. A tampered/expired/wrong-kind token, or a
  missing avatar → 404 (no existence reveal; the SW falls back to the app icon). It can presign NOTHING
  but that user's avatar — the token is inert on every other route.
  """
  def push_avatar(conn, %{"token" => token}) do
    with {:ok, %{user_id: user_id, app_id: app_id}} <- SharedInfra.AvatarToken.verify(token),
         {:ok, url} <- presign_avatar(user_id, app_id) do
      redirect_avatar(conn, url)
    else
      _ -> no_avatar(conn)
    end
  end

  def push_avatar(conn, _params), do: no_avatar(conn)

  # Resolve a user's avatar to a presigned URL, scoped to `app_id`. Cross-tenant (profile not in app),
  # no avatar_media_id, or a media error → :error. object_key is resolved server-side from the row; the
  # "user_avatar" purpose assertion refuses to presign a non-avatar asset.
  defp presign_avatar(user_id, app_id) when is_binary(app_id) and app_id != "" do
    with {:ok, %{avatar_media_id: media_id}} when is_binary(media_id) <-
           SharedInfra.UserClient.get_public_profile(%{"user_id" => user_id, "app_id" => app_id}),
         {:ok, download} <-
           SharedInfra.MediaClient.get_download_url(%{
             "media_id" => media_id,
             "app_id" => app_id,
             "purpose" => "user_avatar"
           }),
         url when is_binary(url) <- Map.get(download, :download_url) do
      {:ok, url}
    else
      _ -> {:error, :no_avatar}
    end
  end

  defp presign_avatar(_user_id, _app_id), do: {:error, :no_avatar}

  defp redirect_avatar(conn, url) do
    conn
    |> put_resp_header("cache-control", "private, max-age=60")
    |> redirect(external: url)
  end

  defp no_avatar(conn), do: conn |> put_status(:not_found) |> json(%{error: %{code: "user.no_avatar"}})

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
           SharedInfra.UserClient.get_public_profile(%{
             "user_id" => user_id,
             "app_id" => session_app(session)
           }) do
      json(conn, present_profile(session.user_id, user_id, response))
    else
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :user_unavailable} -> service_unavailable(conn)
      {:error, :not_found} -> phone_not_found(conn)
      {:error, :self_lookup} -> self_lookup(conn)
      # The number resolved to a user but their profile is malformed OR not in the caller's app — treat as
      # not found rather than leaking a 400 for a lookup whose phone was perfectly valid.
      {:error, :profile_invalid} -> phone_not_found(conn)
      {:error, :profile_not_found} -> phone_not_found(conn)
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
    # Strip avatar_object_key BEFORE anything else — it's accepted (no 400) but never persisted; the server
    # resolves object_key from the media_assets row now.
    params = Map.drop(params, @ignored_update_fields)

    with :ok <- validate_update_payload(params),
         {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         :ok <- validate_avatar_media_id(params, session),
         {:ok, response} <-
           SharedInfra.UserClient.update_current_profile(
             Map.put(params, "user_id", session.user_id)
           ) do
      json(conn, with_avatar_url(response))
    else
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :user_unavailable} -> service_unavailable(conn)
      {:error, :invalid_avatar} -> invalid_avatar(conn)
      {:error, :profile_invalid} -> invalid_request(conn)
      _ -> invalid_request(conn)
    end
  end

  # Stop avatar poisoning: a client-supplied avatar_media_id must be an asset the CALLER owns, of purpose
  # user_avatar, status ready, in the caller's app. Setting it null/"" (removing the avatar) is always OK.
  # Anything else → :invalid_avatar (422). The caller is asserting ownership of an id — not an
  # existence-reveal concern, so a plain 422 (not a 404) is correct.
  defp validate_avatar_media_id(params, session) do
    case Map.get(params, "avatar_media_id") do
      value when value in [nil, ""] ->
        :ok

      media_id when is_binary(media_id) ->
        case SharedInfra.MediaClient.get_asset(%{
               "media_id" => media_id,
               "app_id" => session_app(session)
             }) do
          {:ok, %{owner_user_id: owner, purpose: "user_avatar", status: "ready"}}
          when owner == session.user_id ->
            :ok

          _ ->
            {:error, :invalid_avatar}
        end

      _ ->
        {:error, :invalid_avatar}
    end
  end

  # Enrich a profile map with a ready-to-use signed `avatar_url`. The profile stores `avatar_media_id`
  # + `avatar_object_key`; presigning a download URL needs the object_key (a viewer can't reconstruct
  # another user's key), so the gateway resolves it via the media client and attaches `avatar_url`.
  # Best-effort: any missing field or media error just leaves the profile unchanged (no avatar_url).
  # NOTE: not yet gated by `profile_photo_visibility` (the privacy module is a placeholder today) —
  # avatar visibility gating is a tracked follow-up.
  # Profile as the CALLER may see it. If there's a block in EITHER direction, the account still exists (name
  # shown) but the avatar is hidden — identical to what a caller sees for a user with no avatar, so the block
  # is never revealed (and never leaks "you are blocked"). Last-seen/online is a SEPARATE surface, hidden by
  # SharedInfra.PresenceAuthz. Otherwise the normal presigned-avatar profile.
  defp present_profile(caller_id, target_id, profile) when is_map(profile) do
    if either_blocked?(caller_id, target_id) do
      # Skip the presign entirely and drop the raw avatar id (so the client can't resolve it itself) + the
      # internal app_id; avatar_url: nil is the same shape a genuinely-avatarless profile returns.
      profile
      |> Map.drop([:avatar_media_id, "avatar_media_id", :avatar_object_key, "avatar_object_key", :app_id])
      |> Map.put(:avatar_url, nil)
    else
      with_avatar_url(profile)
    end
  end

  defp present_profile(_caller_id, _target_id, other), do: other

  defp either_blocked?(caller_id, target_id)
       when is_binary(caller_id) and is_binary(target_id) do
    case SharedInfra.ConversationClient.either_blocked?(%{
           "user_a" => caller_id,
           "user_b" => target_id
         }) do
      {:ok, %{blocked: true}} -> true
      {:ok, %{"blocked" => true}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp either_blocked?(_caller_id, _target_id), do: false

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

  # Validate on the params AFTER ignored fields (avatar_object_key) are stripped. An unknown field (e.g.
  # email) still 400s; a lone avatar_object_key (nothing left after stripping) is an empty payload → 400.
  defp validate_update_payload(params) do
    keys = params |> Map.drop(@ignored_update_fields) |> Map.keys() |> Enum.map(&to_string/1)

    if keys != [] and Enum.all?(keys, &(&1 in @allowed_update_fields)) do
      :ok
    else
      {:error, :invalid_request}
    end
  end

  # The caller's tenant, from the session (nil-safe: the placeholder session always carries it).
  defp session_app(session), do: Map.get(session, :app_id)

  defp user_profile_persistence_enabled? do
    Application.get_env(:user_service, :user_profile_persistence, false) ||
      System.get_env("USER_PROFILE_DB_BACKED") == "true"
  end

  defp invalid_request(conn), do: ErrorResponse.invalid_request(conn, "user.invalid_request")

  defp service_unavailable(conn), do: ErrorResponse.service_unavailable(conn, "user.unavailable")

  defp phone_not_found(conn),
    do: ErrorResponse.not_found(conn, "user.phone_not_found", "No account uses this number")

  defp profile_not_found(conn),
    do: ErrorResponse.not_found(conn, "user.not_found", "Not found")

  defp invalid_avatar(conn),
    do:
      ErrorResponse.unprocessable_entity(
        conn,
        "user.invalid_avatar",
        "avatar_media_id must reference your own ready avatar upload"
      )

  defp self_lookup(conn),
    do: ErrorResponse.conflict(conn, "user.self_lookup", "You can't start a chat with yourself")

  defp session_invalid(conn),
    do: ErrorResponse.unauthorized(conn, "auth.session_invalid", "Session token is invalid")
end
