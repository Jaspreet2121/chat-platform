defmodule ApiGatewayWeb.ConversationController do
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  def create(conn, params) do
    if conversation_persistence_enabled?() do
      create_conversation_from_db(conn, params)
    else
      placeholder_create_conversation(conn, params)
    end
  end

  defp placeholder_create_conversation(conn, params) do
    with :ok <- require_fields(params, ["type", "participant_user_ids"]),
         {:ok, response} <- SharedInfra.ConversationClient.create_conversation(params) do
      # Placeholder (persistence off) never carries :created → no broadcast; dev-only, no real sockets.
      ApiGatewayWeb.ConversationBroadcast.broadcast_created(response)

      conn
      |> put_status(:created)
      |> json(ApiGatewayWeb.ConversationBroadcast.strip_internal(response))
    else
      _ -> invalid_request(conn)
    end
  end

  defp create_conversation_from_db(conn, params) do
    with :ok <- require_fields(params, ["type", "participant_user_ids"]),
         {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, response} <-
           params
           |> Map.put("created_by", session.user_id)
           |> SharedInfra.ConversationClient.create_conversation() do
      # Live-update each non-creator participant's inbox on a genuine insert (idempotent direct → no-op).
      ApiGatewayWeb.ConversationBroadcast.broadcast_created(response)

      conn
      |> put_status(:created)
      |> json(ApiGatewayWeb.ConversationBroadcast.strip_internal(response))
    else
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :conversation_unavailable} -> service_unavailable(conn)
      {:error, :conversation_invalid} -> invalid_request(conn)
      _ -> invalid_request(conn)
    end
  end

  def index(conn, params) do
    if conversation_persistence_enabled?() do
      list_conversations_from_db(conn, params)
    else
      placeholder_list_conversations(conn, params)
    end
  end

  defp placeholder_list_conversations(conn, params) do
    with {:ok, response} <- SharedInfra.ConversationClient.list_conversations(params) do
      json(conn, response)
    end
  end

  defp list_conversations_from_db(conn, params) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, response} <-
           params
           |> Map.put("user_id", session.user_id)
           |> SharedInfra.ConversationClient.list_conversations() do
      json(conn, enrich_list_group_avatars(response, session.app_id))
    else
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :conversation_unavailable} -> service_unavailable(conn)
      {:error, :conversation_invalid} -> invalid_request(conn)
      _ -> invalid_request(conn)
    end
  end

  def show(conn, %{"conversation_id" => conversation_id} = params) do
    if conversation_persistence_enabled?() do
      show_conversation_from_db(conn, conversation_id, params)
    else
      placeholder_show_conversation(conn, conversation_id, params)
    end
  end

  defp placeholder_show_conversation(conn, conversation_id, params) do
    params = Map.put(params, "conversation_id", conversation_id)

    with {:ok, response} <- SharedInfra.ConversationClient.get_conversation(params) do
      json(conn, response)
    end
  end

  defp show_conversation_from_db(conn, conversation_id, params) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, response} <-
           params
           |> Map.put("conversation_id", conversation_id)
           |> Map.put("user_id", session.user_id)
           |> SharedInfra.ConversationClient.get_conversation() do
      json(conn, with_group_avatar_url(response, session.app_id))
    else
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :conversation_unavailable} -> service_unavailable(conn)
      {:error, :conversation_invalid} -> invalid_request(conn)
      {:error, :conversation_not_found} -> invalid_request(conn)
      {:error, :conversation_forbidden} -> invalid_request(conn)
      _ -> invalid_request(conn)
    end
  end

  # GET /api/v1/conversations/:id/ongoing-call → { ongoing_call: {call_id, room, type} | null }. Powers the
  # "join group call" banner (Slice C1). Membership-gated the SAME way as show/1 — get_conversation returns
  # :conversation_forbidden for non-members. A non-member / unknown conversation / no call → { ongoing_call:
  # null } (never errors, never reveals existence).
  def ongoing_call(conn, %{"conversation_id" => conversation_id}) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, _conversation} <-
           SharedInfra.ConversationClient.get_conversation(%{
             "conversation_id" => conversation_id,
             "user_id" => session.user_id
           }),
         {:ok, result} <-
           SharedInfra.ConversationClient.get_ongoing_group_call(%{
             "conversation_id" => conversation_id
           }) do
      call = Map.get(result, :call) || Map.get(result, "call")
      json(conn, %{ongoing_call: ongoing_call_view(call)})
    else
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      # Non-member / unknown conversation / persistence off → no banner (no existence reveal).
      _ -> json(conn, %{ongoing_call: nil})
    end
  end

  defp ongoing_call_view(call) when is_map(call) do
    %{
      call_id: Map.get(call, :id) || Map.get(call, "id"),
      room: Map.get(call, :room_name) || Map.get(call, "room_name"),
      type: Map.get(call, :type) || Map.get(call, "type")
    }
  end

  defp ongoing_call_view(_), do: nil

  # USER-SCOPED soft-hides (nothing is deleted; only the caller's own participant row is written).
  # "Clear chat for me": stamps cleared_before = now() on the caller's membership row.
  def clear(conn, %{"conversation_id" => conversation_id}) do
    # pref_mutation (not with_own_participant): the caller's OTHER devices must see the cleared state
    # live. The :pref frame's row is recomputed AFTER the clear commits — the inbox SQL applies
    # cleared_before to BOTH the preview lateral and the unread lateral, so the frame carries the
    # post-clear preview/unread (verified by test), never a stale row.
    pref_mutation(conn, conversation_id, fn user_id ->
      SharedInfra.ConversationClient.clear_history(%{
        "conversation_id" => conversation_id,
        "user_id" => user_id
      })
    end)
  end

  # "Disappearing messages" (off / after_viewing / 8h / 24h / 7d): sets the rolling view window (or
  # after-viewing flag). scope "mine" narrows only the caller's view; "both" narrows every participant's.
  def auto_delete(conn, %{"conversation_id" => conversation_id} = params) do
    pref_mutation(conn, conversation_id, fn user_id ->
      SharedInfra.ConversationClient.set_auto_delete(%{
        "conversation_id" => conversation_id,
        "user_id" => user_id,
        "mode" => params["mode"],
        "scope" => params["scope"]
      })
    end)
  end

  # "Mute notifications" (off / 8h / 1w / always): suppresses WEB-PUSH for the caller in this chat.
  def mute(conn, %{"conversation_id" => conversation_id} = params) do
    pref_mutation(conn, conversation_id, fn user_id ->
      SharedInfra.ConversationClient.set_mute(%{
        "conversation_id" => conversation_id,
        "user_id" => user_id,
        "mode" => params["mode"]
      })
    end)
  end

  # ARCHIVE for the caller — a soft list-placement hide: the chat leaves the default inbox (fetched via
  # GET /conversations?archived=true) but is never muted or deleted. {"archived": false} unarchives.
  def archive(conn, %{"conversation_id" => conversation_id} = params) do
    pref_mutation(conn, conversation_id, fn user_id ->
      SharedInfra.ConversationClient.set_archive(%{
        "conversation_id" => conversation_id,
        "user_id" => user_id,
        "archived" => params["archived"]
      })
    end)
  end

  # PIN for the caller — sorts the chat above the rest. Over the server cap → 400 conversations.pin_limit
  # {limit}. {"pinned": false} unpins.
  def pin(conn, %{"conversation_id" => conversation_id} = params) do
    pref_mutation(conn, conversation_id, fn user_id ->
      SharedInfra.ConversationClient.set_pin(%{
        "conversation_id" => conversation_id,
        "user_id" => user_id,
        "pinned" => params["pinned"]
      })
    end)
  end

  # Like with_own_participant, but ALSO broadcasts conversation_updated (:pref) to the caller's OTHER devices —
  # a per-user pref changes what THEIR open clients must show, so they update live. `only: [me]` because a
  # per-user pref is invisible to everyone else. ALL FIVE per-user prefs route through here: archive, pin,
  # mute, clear-history, auto-delete (the last three previously broadcast nothing — devices went stale).
  defp pref_mutation(conn, conversation_id, operation) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, response} <- operation.(session.user_id) do
      ApiGatewayWeb.ConversationBroadcast.broadcast_updated(
        conversation_id,
        session.user_id,
        :pref,
        only: [session.user_id]
      )

      json(conn, response)
    else
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :conversation_unavailable} -> service_unavailable(conn)
      {:error, :not_participant} -> forbidden_membership(conn)
      {:error, :pin_limit} -> pin_limit(conn)
      _ -> invalid_request(conn)
    end
  end

  # WhatsApp caps pins at 3 — keep in sync with ConversationService.Participants.pin_limit/0.
  @pin_limit 3

  defp pin_limit(conn) do
    ApiGatewayWeb.ErrorResponse.invalid_request_with(
      conn,
      "conversations.pin_limit",
      "Too many pinned conversations",
      %{limit: @pin_limit}
    )
  end

  # Group name/photo update — OWNER-gated by the conversation service (the caller must be an active
  # owner/admin). Empty-string avatar fields clear the photo. Returns the fresh group_avatar_url.
  def group_profile(conn, %{"conversation_id" => conversation_id} = params) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, response} <-
           SharedInfra.ConversationClient.set_group_profile(%{
             "conversation_id" => conversation_id,
             "actor_user_id" => session.user_id,
             "name" => params["name"],
             "avatar_media_id" => params["avatar_media_id"],
             "avatar_object_key" => params["avatar_object_key"]
           }) do
      # TITLE trigger: a group rename (group_profiles.name — the source of truth the inbox now COALESCEs to)
      # must reach every participant's inbox live. Also covers a photo change, which alters the same row.
      ApiGatewayWeb.ConversationBroadcast.broadcast_updated(
        conversation_id,
        session.user_id,
        :title
      )

      json(conn, with_group_avatar_url(response, session.app_id))
    else
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :conversation_unavailable} -> service_unavailable(conn)
      {:error, :conversation_forbidden} ->
        ErrorResponse.forbidden(conn, "conversation.not_owner", "Only the group owner can change this")

      _ -> invalid_request(conn)
    end
  end

  # OWNER-only: promote/demote a member (role: "admin" | "member"). The conversation service enforces
  # that the caller is the owner and the target isn't the owner.
  def set_participant_role(conn, %{"conversation_id" => conversation_id, "user_id" => user_id} = params) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, response} <-
           SharedInfra.ConversationClient.set_participant_role(%{
             "conversation_id" => conversation_id,
             "user_id" => user_id,
             "actor_user_id" => session.user_id,
             "role" => params["role"]
           }) do
      json(conn, response)
    else
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :conversation_unavailable} -> service_unavailable(conn)
      {:error, :participant_forbidden} ->
        ErrorResponse.forbidden(conn, "conversation.not_owner", "Only the group owner can manage admins")

      _ -> invalid_request(conn)
    end
  end

  # OWNER or ADMIN: toggle group settings — only_admins_can_send and/or call_start_permission. Forwards
  # ONLY the fields the client sent, so toggling one setting never clobbers the other.
  def set_group_settings(conn, %{"conversation_id" => conversation_id} = params) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, response} <-
           SharedInfra.ConversationClient.set_group_settings(
             settings_attrs(conversation_id, session.user_id, params)
           ) do
      json(conn, response)
    else
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :conversation_unavailable} -> service_unavailable(conn)
      {:error, :participant_forbidden} ->
        ErrorResponse.forbidden(conn, "conversation.not_admin", "Only an owner or admin can change this")

      _ -> invalid_request(conn)
    end
  end

  # Build the settings attrs, including a field ONLY when the client actually sent it (so a
  # call_start_permission-only update doesn't reset only_admins_can_send, and vice-versa).
  defp settings_attrs(conversation_id, actor_user_id, params) do
    %{"conversation_id" => conversation_id, "actor_user_id" => actor_user_id}
    |> maybe_put_param("only_admins_can_send", params)
    |> maybe_put_param("call_start_permission", params)
  end

  defp maybe_put_param(attrs, key, params) do
    case Map.get(params, key) do
      nil -> attrs
      value -> Map.put(attrs, key, value)
    end
  end

  # Presign a group's avatar (media_id + object_key) → group_avatar_url. Mirrors user with_avatar_url.
  # Best-effort: missing fields / media error → the map is unchanged (no group_avatar_url).
  # `app_id` is the caller's session tenant. A caller only ever sees groups in their own app (membership),
  # so it equals the conversation's app_id; a mismatch just fails safe to no-avatar (the row lookup misses).
  # object_key is resolved server-side from the row; the "group_avatar" purpose assertion refuses to presign
  # a non-group-avatar asset.
  defp with_group_avatar_url(map, app_id) when is_map(map) and is_binary(app_id) do
    with media_id when is_binary(media_id) <-
           Map.get(map, :group_avatar_media_id) || Map.get(map, "group_avatar_media_id"),
         {:ok, download} <-
           SharedInfra.MediaClient.get_download_url(%{
             "media_id" => media_id,
             "app_id" => app_id,
             "purpose" => "group_avatar"
           }),
         url when is_binary(url) <-
           Map.get(download, :download_url) || Map.get(download, "download_url") do
      Map.put(map, :group_avatar_url, url)
    else
      _ -> map
    end
  end

  defp with_group_avatar_url(other, _app_id), do: other

  # Presign group avatars for the LIST concurrently (only group rows with a photo). Bounded fan-out;
  # a failed presign just leaves that row without a group_avatar_url (client falls back to initials).
  defp enrich_list_group_avatars(%{conversations: conversations} = response, app_id)
       when is_list(conversations) do
    %{response | conversations: enrich_rows(conversations, app_id)}
  end

  defp enrich_list_group_avatars(%{"conversations" => conversations} = response, app_id)
       when is_list(conversations) do
    Map.put(response, "conversations", enrich_rows(conversations, app_id))
  end

  defp enrich_list_group_avatars(other, _app_id), do: other

  defp enrich_rows(conversations, app_id) do
    conversations
    |> Task.async_stream(fn row -> with_group_avatar_url(row, app_id) end,
      max_concurrency: 8,
      timeout: 5_000,
      on_timeout: :kill_task,
      zip_input_on_exit: true,
      ordered: true
    )
    |> Enum.map(fn
      {:ok, row} -> row
      {:exit, {row, _reason}} -> row
    end)
  end

  # Shared session gate for the self-scoped ops above. Membership is enforced by the service (the
  # UPDATE only matches the caller's own ACTIVE participant row → non-members get 403).
  defp forbidden_membership(conn),
    do: ErrorResponse.forbidden(conn, "conversation.not_participant", "Not a participant")

  def add_participant(conn, %{"conversation_id" => conversation_id} = params) do
    if conversation_persistence_enabled?() do
      add_participant_from_db(conn, conversation_id, params)
    else
      placeholder_add_participant(conn, conversation_id, params)
    end
  end

  defp placeholder_add_participant(conn, conversation_id, params) do
    with :ok <- require_fields(params, ["user_id"]),
         {:ok, response} <-
           params
           |> Map.put("conversation_id", conversation_id)
           |> SharedInfra.ConversationClient.add_participant() do
      json(conn, response)
    else
      _ -> invalid_request(conn)
    end
  end

  defp add_participant_from_db(conn, conversation_id, params) do
    with :ok <- require_fields(params, ["user_id"]),
         {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, response} <-
           params
           |> Map.put("conversation_id", conversation_id)
           |> Map.put("actor_user_id", session.user_id)
           |> SharedInfra.ConversationClient.add_participant() do
      # Every participant's row changes (the participant set moved) — INCLUDING the newly added member, who is
      # now an active participant and so gets a row from inbox_rows. That is how the conversation APPEARS in
      # their inbox: via conversation_updated, NOT conversation_created (the conversation already existed).
      ApiGatewayWeb.ConversationBroadcast.broadcast_updated(
        conversation_id,
        session.user_id,
        :participant
      )

      json(conn, response)
    else
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :conversation_unavailable} -> service_unavailable(conn)
      _ -> invalid_request(conn)
    end
  end

  def remove_participant(conn, %{"conversation_id" => conversation_id, "user_id" => user_id}) do
    if conversation_persistence_enabled?() do
      remove_participant_from_db(conn, conversation_id, user_id)
    else
      placeholder_remove_participant(conn, conversation_id, user_id)
    end
  end

  @doc """
  VOLUNTARY leave (078) — POST /:conversation_id/leave. Self-removal, distinct from the moderation
  removal above (owner/admin invariants untouched): the row is marked left_reason='left', so a live
  invite link may readmit the leaver. The owner leaving transfers ownership (oldest admin, else oldest
  member — `new_owner_user_id` in the response); the last participant leaving archives the conversation.

  NOTE the frame limitation: the `:participant` broadcast refreshes every member's inbox ROW, but rows
  don't carry `role` — a promoted new owner must re-fetch the conversation detail to learn they now own
  it. COMPATIBILITY SHIM: shipped Android calls DELETE /:id/participants/{own_id} to leave — the
  remove_participant action above detects the self-target and routes HERE. /leave is the canonical
  route; the shim is deliberate, not accidental duplication — do not remove it while pre-078 Android
  builds are live.
  """
  def leave(conn, %{"conversation_id" => conversation_id}) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, response} <-
           SharedInfra.ConversationClient.leave_conversation(%{
             "conversation_id" => conversation_id,
             "user_id" => session.user_id
           }) do
      # Same fan-out as a removal: remaining members get refreshed rows; the LEAVER gets the final
      # `removed: true` frame that clears their inbox entry.
      ApiGatewayWeb.ConversationBroadcast.broadcast_updated(
        conversation_id,
        session.user_id,
        :participant,
        removed_user_id: session.user_id
      )

      json(conn, response)
    else
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :conversation_unavailable} -> service_unavailable(conn)
      {:error, :not_a_group} -> ErrorResponse.invalid_request(conn, "conversation.not_a_group")
      {:error, :participant_not_found} -> ErrorResponse.not_found(conn, "conversation.not_found", "Not found")
      {:error, :conversation_not_found} -> ErrorResponse.not_found(conn, "conversation.not_found", "Not found")
      _ -> invalid_request(conn)
    end
  end

  defp placeholder_remove_participant(conn, conversation_id, user_id) do
    with {:ok, response} <-
           SharedInfra.ConversationClient.remove_participant(%{
             "conversation_id" => conversation_id,
             "user_id" => user_id
           }) do
      json(conn, response)
    end
  end

  defp remove_participant_from_db(conn, conversation_id, user_id) do
    case session_from(conn) do
      {:ok, session} when session.user_id == user_id ->
        # COMPATIBILITY SHIM: a SELF-target has always been a "leave" (shipped Android calls
        # DELETE /:id/participants/{own_id} for Leave group — it could only 403 against the moderation
        # gates). Route it to the canonical leave path (POST /:id/leave); the moderation invariants
        # below stay untouched. Deliberate, not accidental duplication — keep while pre-078 builds live.
        leave(conn, %{"conversation_id" => conversation_id})

      {:ok, session} ->
        moderation_remove(conn, conversation_id, user_id, session)

      {:error, _reason} ->
        session_invalid(conn)
    end
  end

  defp moderation_remove(conn, conversation_id, user_id, session) do
    with {:ok, response} <-
           SharedInfra.ConversationClient.remove_participant(%{
             "conversation_id" => conversation_id,
             "user_id" => user_id,
             "actor_user_id" => session.user_id
           }) do
      # The REMAINING members get an updated row; the REMOVED member gets one final frame carrying
      # `removed: true` (they are no longer an active participant, so they have no inbox row to send — without
      # this their inbox would keep a dead entry until a refetch).
      ApiGatewayWeb.ConversationBroadcast.broadcast_updated(
        conversation_id,
        session.user_id,
        :participant,
        removed_user_id: user_id
      )

      json(conn, response)
    else
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :conversation_unavailable} -> service_unavailable(conn)
      _ -> invalid_request(conn)
    end
  end

  defp session_from(conn) do
    with {:ok, authorization} <- authorization_header(conn) do
      SharedInfra.AuthClient.current_session(%{"authorization" => authorization})
    end
  end

  defp require_fields(params, fields) do
    if Enum.all?(fields, &present?(params[&1])) do
      :ok
    else
      {:error, :invalid_request}
    end
  end

  defp present?(value), do: not is_nil(value) and value != "" and value != []

  defp invalid_request(conn),
    do: ErrorResponse.invalid_request(conn, "conversation.invalid_request")

  defp service_unavailable(conn),
    do: ErrorResponse.service_unavailable(conn, "conversation.unavailable")

  defp authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> _token = authorization] -> {:ok, authorization}
      _ -> {:error, :session_invalid}
    end
  end

  defp session_invalid(conn),
    do: ErrorResponse.unauthorized(conn, "auth.session_invalid", "Invalid or expired session")

  defp conversation_persistence_enabled? do
    Application.get_env(:conversation_service, :conversation_persistence, false) ||
      System.get_env("CONVERSATION_DB_BACKED") in ["true", "1", "yes"]
  end
end
