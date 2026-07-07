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
      conn
      |> put_status(:created)
      |> json(response)
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
      conn
      |> put_status(:created)
      |> json(response)
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
      json(conn, enrich_list_group_avatars(response))
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
      json(conn, with_group_avatar_url(response))
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
    with_own_participant(conn, fn user_id ->
      SharedInfra.ConversationClient.clear_history(%{
        "conversation_id" => conversation_id,
        "user_id" => user_id
      })
    end)
  end

  # "Disappearing messages" (off / after_viewing / 8h / 24h / 7d): sets the rolling view window (or
  # after-viewing flag). scope "mine" narrows only the caller's view; "both" narrows every participant's.
  def auto_delete(conn, %{"conversation_id" => conversation_id} = params) do
    with_own_participant(conn, fn user_id ->
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
    with_own_participant(conn, fn user_id ->
      SharedInfra.ConversationClient.set_mute(%{
        "conversation_id" => conversation_id,
        "user_id" => user_id,
        "mode" => params["mode"]
      })
    end)
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
      json(conn, with_group_avatar_url(response))
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

  # OWNER or ADMIN: toggle group settings (only_admins_can_send).
  def set_group_settings(conn, %{"conversation_id" => conversation_id} = params) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, response} <-
           SharedInfra.ConversationClient.set_group_settings(%{
             "conversation_id" => conversation_id,
             "actor_user_id" => session.user_id,
             "only_admins_can_send" => params["only_admins_can_send"]
           }) do
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

  # Presign a group's avatar (media_id + object_key) → group_avatar_url. Mirrors user with_avatar_url.
  # Best-effort: missing fields / media error → the map is unchanged (no group_avatar_url).
  defp with_group_avatar_url(map) when is_map(map) do
    with media_id when is_binary(media_id) <-
           Map.get(map, :group_avatar_media_id) || Map.get(map, "group_avatar_media_id"),
         object_key when is_binary(object_key) <-
           Map.get(map, :group_avatar_object_key) || Map.get(map, "group_avatar_object_key"),
         owner when is_binary(owner) <-
           Map.get(map, :conversation_id) || Map.get(map, "conversation_id"),
         {:ok, download} <-
           SharedInfra.MediaClient.get_download_url(%{
             "media_id" => media_id,
             "owner_user_id" => owner,
             "object_key" => object_key
           }),
         url when is_binary(url) <-
           Map.get(download, :download_url) || Map.get(download, "download_url") do
      Map.put(map, :group_avatar_url, url)
    else
      _ -> map
    end
  end

  defp with_group_avatar_url(other), do: other

  # Presign group avatars for the LIST concurrently (only group rows with a photo). Bounded fan-out;
  # a failed presign just leaves that row without a group_avatar_url (client falls back to initials).
  defp enrich_list_group_avatars(%{conversations: conversations} = response)
       when is_list(conversations) do
    %{response | conversations: enrich_rows(conversations)}
  end

  defp enrich_list_group_avatars(%{"conversations" => conversations} = response)
       when is_list(conversations) do
    Map.put(response, "conversations", enrich_rows(conversations))
  end

  defp enrich_list_group_avatars(other), do: other

  defp enrich_rows(conversations) do
    conversations
    |> Task.async_stream(&with_group_avatar_url/1,
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
  defp with_own_participant(conn, operation) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, response} <- operation.(session.user_id) do
      json(conn, response)
    else
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :conversation_unavailable} -> service_unavailable(conn)
      {:error, :not_participant} -> forbidden_membership(conn)
      _ -> invalid_request(conn)
    end
  end

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
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, response} <-
           SharedInfra.ConversationClient.remove_participant(%{
             "conversation_id" => conversation_id,
             "user_id" => user_id,
             "actor_user_id" => session.user_id
           }) do
      json(conn, response)
    else
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :conversation_unavailable} -> service_unavailable(conn)
      _ -> invalid_request(conn)
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
