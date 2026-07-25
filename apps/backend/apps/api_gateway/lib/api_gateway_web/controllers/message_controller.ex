defmodule ApiGatewayWeb.MessageController do
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  def create(conn, %{"conversation_id" => conversation_id} = params) do
    if message_persistence_enabled?() do
      create_message_from_store(conn, conversation_id, params)
    else
      placeholder_create_message(conn, conversation_id, params)
    end
  end

  defp placeholder_create_message(conn, conversation_id, params) do
    params = Map.put(params, "conversation_id", conversation_id)

    with :ok <- validate_send_payload(params),
         {:ok, response} <- SharedInfra.MessageClient.send_message(params) do
      conn
      |> put_status(:created)
      |> json(response)
    else
      _ -> invalid_request(conn)
    end
  end

  defp create_message_from_store(conn, conversation_id, params) do
    params = Map.put(params, "conversation_id", conversation_id)

    with :ok <- validate_send_payload(params),
         {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         :ok <- authorize_membership(conversation_id, session.user_id),
         # SERVER-SIDE only-admins-can-send enforcement (a member can't bypass via the API). This SAME call
         # also carries the BLOCK disposition: for a DIRECT chat the recipient has blocked, delivery: "drop".
         {:ok, disposition} <-
           SharedInfra.ConversationClient.authorize_send(%{
             "conversation_id" => conversation_id,
             "user_id" => session.user_id
           }),
         dropped? = dropped?(disposition),
         {:ok, response} <-
           params
           |> Map.put("sender_user_id", session.user_id)
           |> put_delivery(dropped?)
           |> SharedInfra.MessageClient.create_message() do
      # A DROPPED (blocked) message returns a canonical single-tick ack to the SENDER but reaches the blocker
      # through NO path: nothing persisted, and the inbox fan-out below (which would wake the blocker's list)
      # is skipped. The sender learns nothing.
      unless dropped? do
        # Live inbox: new preview + updated_at for all, +1 unread for everyone but the sender.
        ApiGatewayWeb.ConversationBroadcast.broadcast_updated(
          conversation_id,
          session.user_id,
          :message
        )
      end

      conn
      |> put_status(:created)
      |> json(response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :message_unavailable} -> service_unavailable(conn)
      {:error, :conversation_unavailable} -> service_unavailable(conn)
      {:error, :conversation_membership_forbidden} -> forbidden(conn)
      {:error, :only_admins_can_send} ->
        ErrorResponse.forbidden(conn, "group.only_admins_can_send", "Only admins can send messages")

      _ -> invalid_request(conn)
    end
  end

  def index(conn, %{"conversation_id" => conversation_id} = params) do
    if message_persistence_enabled?() do
      list_messages_from_store(conn, conversation_id, params)
    else
      placeholder_list_messages(conn, conversation_id, params)
    end
  end

  defp placeholder_list_messages(conn, conversation_id, params) do
    params = Map.put(params, "conversation_id", conversation_id)

    with {:ok, response} <- SharedInfra.MessageClient.list_timeline(params) do
      json(conn, response)
    end
  end

  defp list_messages_from_store(conn, conversation_id, params) do
    params = Map.put(params, "conversation_id", conversation_id)

    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         :ok <- authorize_membership(conversation_id, session.user_id),
         {:ok, response} <-
           params
           |> Map.put("viewer_user_id", session.user_id)
           |> SharedInfra.MessageClient.list_messages() do
      json(conn, response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :message_unavailable} -> service_unavailable(conn)
      {:error, :conversation_unavailable} -> service_unavailable(conn)
      {:error, :conversation_membership_forbidden} -> forbidden(conn)
      _ -> invalid_request(conn)
    end
  end

  # Shared-media gallery: the conversation's media messages (newest first, cursor-paginated).
  # Membership-gated EXACTLY like the timeline; the viewer's clear-chat/auto-delete window applies
  # (viewer_user_id passed); presigned URLs are resolved client-side per item (same as chat bubbles).
  def media(conn, %{"conversation_id" => conversation_id} = params) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         :ok <- authorize_membership(conversation_id, session.user_id),
         {:ok, response} <-
           SharedInfra.MessageClient.list_media(%{
             "conversation_id" => conversation_id,
             "viewer_user_id" => session.user_id,
             "limit" => params["limit"],
             "before" => params["before"]
           }) do
      json(conn, response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :message_unavailable} -> service_unavailable(conn)
      {:error, :conversation_unavailable} -> service_unavailable(conn)
      {:error, :conversation_membership_forbidden} -> forbidden(conn)
      _ -> invalid_request(conn)
    end
  end

  # Set/change the caller's reaction on a message (WhatsApp one-per-user). Members only.
  def react(conn, %{"conversation_id" => conversation_id, "message_id" => message_id} = params) do
    with {:ok, emoji} <- require_emoji(params),
         {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         :ok <- authorize_membership(conversation_id, session.user_id),
         {:ok, response} <-
           SharedInfra.MessageClient.add_reaction(%{
             "conversation_id" => conversation_id,
             "message_id" => message_id,
             "user_id" => session.user_id,
             "emoji" => emoji
           }) do
      json(conn, response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :message_unavailable} -> service_unavailable(conn)
      {:error, :conversation_unavailable} -> service_unavailable(conn)
      {:error, :conversation_membership_forbidden} -> forbidden(conn)
      _ -> invalid_request(conn)
    end
  end

  # Remove the caller's reaction from a message.
  def unreact(conn, %{"conversation_id" => conversation_id, "message_id" => message_id}) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         :ok <- authorize_membership(conversation_id, session.user_id),
         {:ok, response} <-
           SharedInfra.MessageClient.remove_reaction(%{
             "message_id" => message_id,
             "user_id" => session.user_id
           }) do
      json(conn, response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :message_unavailable} -> service_unavailable(conn)
      {:error, :conversation_unavailable} -> service_unavailable(conn)
      {:error, :conversation_membership_forbidden} -> forbidden(conn)
      _ -> invalid_request(conn)
    end
  end

  defp require_emoji(params) do
    case Map.get(params, "emoji") do
      emoji when is_binary(emoji) and emoji != "" -> {:ok, emoji}
      _ -> {:error, :invalid_request}
    end
  end

  # Star (bookmark) a message for the caller — private, no broadcast. Members only.
  def star(conn, %{"conversation_id" => conversation_id, "message_id" => message_id}) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         :ok <- authorize_membership(conversation_id, session.user_id),
         {:ok, response} <-
           SharedInfra.MessageClient.star_message(%{
             "conversation_id" => conversation_id,
             "message_id" => message_id,
             "user_id" => session.user_id
           }) do
      json(conn, response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :message_unavailable} -> service_unavailable(conn)
      {:error, :conversation_unavailable} -> service_unavailable(conn)
      {:error, :conversation_membership_forbidden} -> forbidden(conn)
      _ -> invalid_request(conn)
    end
  end

  # Unstar a message for the caller.
  def unstar(conn, %{"conversation_id" => conversation_id, "message_id" => message_id}) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         :ok <- authorize_membership(conversation_id, session.user_id),
         {:ok, response} <-
           SharedInfra.MessageClient.unstar_message(%{
             "message_id" => message_id,
             "user_id" => session.user_id
           }) do
      json(conn, response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :message_unavailable} -> service_unavailable(conn)
      {:error, :conversation_unavailable} -> service_unavailable(conn)
      {:error, :conversation_membership_forbidden} -> forbidden(conn)
      _ -> invalid_request(conn)
    end
  end

  def update(conn, %{"conversation_id" => conversation_id, "message_id" => message_id} = params) do
    if message_persistence_enabled?() do
      update_message_in_store(conn, conversation_id, message_id, params)
    else
      placeholder_update_message(conn, conversation_id, message_id, params)
    end
  end

  defp placeholder_update_message(conn, conversation_id, message_id, params) do
    params =
      params
      |> Map.put("conversation_id", conversation_id)
      |> Map.put("message_id", message_id)

    with :ok <- require_fields(params, ["body"]),
         {:ok, response} <- SharedInfra.MessageClient.edit_message(params) do
      json(conn, response)
    else
      _ -> invalid_request(conn)
    end
  end

  defp update_message_in_store(conn, conversation_id, message_id, params) do
    params =
      params
      |> Map.put("conversation_id", conversation_id)
      |> Map.put("message_id", message_id)

    with :ok <- require_fields(params, ["body"]),
         {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, response} <-
           params
           |> Map.put("actor_user_id", session.user_id)
           |> SharedInfra.MessageClient.update_message() do
      json(conn, response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :message_unavailable} -> service_unavailable(conn)
      {:error, :message_forbidden} -> forbidden(conn)
      # A soft-deleted message is GONE — an edit would resurrect the tombstone. 404, not 403: it isn't a
      # permission problem (you DO own it), the message simply no longer exists to edit.
      {:error, :message_deleted} -> not_found(conn)
      _ -> invalid_request(conn)
    end
  end

  def delete(conn, %{"conversation_id" => conversation_id, "message_id" => message_id}) do
    if message_persistence_enabled?() do
      delete_message_from_store(conn, conversation_id, message_id)
    else
      placeholder_delete_message(conn, conversation_id, message_id)
    end
  end

  defp placeholder_delete_message(conn, conversation_id, message_id) do
    with {:ok, response} <-
           SharedInfra.MessageClient.delete_message(%{
             "conversation_id" => conversation_id,
             "message_id" => message_id
           }) do
      json(conn, response)
    end
  end

  defp delete_message_from_store(conn, conversation_id, message_id) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, response} <-
           SharedInfra.MessageClient.delete_message(%{
             "conversation_id" => conversation_id,
             "message_id" => message_id,
             "actor_user_id" => session.user_id
           }) do
      json(conn, response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :message_unavailable} -> service_unavailable(conn)
      {:error, :message_forbidden} -> forbidden(conn)
      _ -> invalid_request(conn)
    end
  end

  def read(conn, %{"conversation_id" => conversation_id, "message_id" => message_id}) do
    if message_persistence_enabled?() do
      mark_read_in_store(conn, conversation_id, message_id)
    else
      placeholder_mark_read(conn, conversation_id, message_id)
    end
  end

  defp placeholder_mark_read(conn, conversation_id, message_id) do
    with {:ok, response} <-
           SharedInfra.MessageClient.mark_read(%{
             "conversation_id" => conversation_id,
             "message_id" => message_id
           }) do
      json(conn, response)
    end
  end

  defp mark_read_in_store(conn, conversation_id, message_id) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         # BEFORE the write: re-reading an already-read message leaves unread unchanged, and an identical
         # inbox row must not be re-broadcast on every such call.
         unread_before <-
           ApiGatewayWeb.ConversationBroadcast.unread_before(conversation_id, session.user_id),
         {:ok, response} <-
           SharedInfra.MessageClient.mark_read(%{
             "conversation_id" => conversation_id,
             "message_id" => message_id,
             "user_id" => session.user_id
           }) do
      # Only the READER's badge changed → fan out to them alone, and only if it actually moved.
      ApiGatewayWeb.ConversationBroadcast.broadcast_updated(
        conversation_id,
        session.user_id,
        :receipt,
        only: [session.user_id],
        skip_if_unread: unread_before
      )

      json(conn, response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :message_unavailable} -> service_unavailable(conn)
      _ -> invalid_request(conn)
    end
  end

  def delivered(conn, %{"conversation_id" => conversation_id, "message_id" => message_id}) do
    if message_persistence_enabled?() do
      mark_delivered_in_store(conn, conversation_id, message_id)
    else
      placeholder_mark_delivered(conn, conversation_id, message_id)
    end
  end

  defp placeholder_mark_delivered(conn, conversation_id, message_id) do
    with {:ok, response} <-
           SharedInfra.MessageClient.mark_delivered(%{
             "conversation_id" => conversation_id,
             "message_id" => message_id
           }) do
      json(conn, response)
    end
  end

  defp mark_delivered_in_store(conn, conversation_id, message_id) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, response} <-
           SharedInfra.MessageClient.mark_delivered(%{
             "conversation_id" => conversation_id,
             "message_id" => message_id,
             "user_id" => session.user_id
           }) do
      json(conn, response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :message_unavailable} -> service_unavailable(conn)
      _ -> invalid_request(conn)
    end
  end

  defp validate_send_payload(%{"message_type" => "text"} = params) do
    require_fields(params, ["body"])
  end

  defp validate_send_payload(params), do: require_fields(params, ["message_type"])

  defp require_fields(params, fields) do
    if Enum.all?(fields, &present?(params[&1])) do
      :ok
    else
      {:error, :invalid_request}
    end
  end

  defp present?(value), do: not is_nil(value) and value != ""

  # The send gate's disposition: delivery: "drop" means the recipient blocked the sender (DIRECT chat).
  defp dropped?(disposition) when is_map(disposition),
    do: Map.get(disposition, :delivery) == "drop" or Map.get(disposition, "delivery") == "drop"

  defp dropped?(_disposition), do: false

  # SERVER-controlled flag: set on a drop, STRIP any client-injected value otherwise (a client must never be
  # able to force the synthesize path).
  defp put_delivery(params, true), do: Map.put(params, "delivery_disposition", "drop")
  defp put_delivery(params, false), do: Map.delete(params, "delivery_disposition")

  defp invalid_request(conn), do: ErrorResponse.invalid_request(conn, "message.invalid_request")

  defp not_found(conn),
    do: ErrorResponse.not_found(conn, "message.not_found", "Message not found")

  defp service_unavailable(conn),
    do: ErrorResponse.service_unavailable(conn, "message.unavailable")

  defp unauthorized(conn),
    do:
      ErrorResponse.unauthorized(conn, "message.unauthorized", "Missing or invalid access token")

  defp forbidden(conn),
    do:
      ErrorResponse.forbidden(conn, "message.forbidden", "You can only modify your own messages")

  defp authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> _token = authorization] -> {:ok, authorization}
      _ -> {:error, :session_invalid}
    end
  end

  # Membership gate for HTTP message create/list, reusing the same Conversation
  # Service check the realtime channel-join path uses. When conversation
  # persistence is OFF, get_conversation returns a placeholder {:ok} so the
  # placeholder/Docker-free path is unchanged (enforcement is only meaningful
  # when conversation persistence is enabled).
  defp authorize_membership(conversation_id, user_id) do
    case SharedInfra.ConversationClient.get_conversation(%{
           "conversation_id" => conversation_id,
           "user_id" => user_id
         }) do
      {:ok, _conversation} -> :ok
      # Propagate transport-unavailable so the controller maps it to 503 (not a 403 forbidden).
      {:error, :conversation_unavailable} -> {:error, :conversation_unavailable}
      _ -> {:error, :conversation_membership_forbidden}
    end
  end

  defp message_persistence_enabled? do
    Application.get_env(:message_service, :message_persistence, false) ||
      System.get_env("MESSAGE_DB_BACKED") in ["true", "1", "yes"]
  end
end
