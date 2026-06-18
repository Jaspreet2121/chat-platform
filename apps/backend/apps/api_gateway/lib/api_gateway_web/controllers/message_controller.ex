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
         {:ok, response} <- MessageService.Messages.send_message(params) do
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
         {:ok, response} <-
           params
           |> Map.put("sender_user_id", session.user_id)
           |> MessageService.Messages.create_message() do
      conn
      |> put_status(:created)
      |> json(response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
      {:error, :conversation_membership_forbidden} -> forbidden(conn)
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

    with {:ok, response} <- MessageService.Timeline.list_messages(params) do
      json(conn, response)
    end
  end

  defp list_messages_from_store(conn, conversation_id, params) do
    params = Map.put(params, "conversation_id", conversation_id)

    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         :ok <- authorize_membership(conversation_id, session.user_id),
         {:ok, response} <- MessageService.Messages.list_messages(params) do
      json(conn, response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
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
         {:ok, response} <- MessageService.Messages.edit_message(params) do
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
           |> MessageService.Messages.update_message() do
      json(conn, response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
      {:error, :message_forbidden} -> forbidden(conn)
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
           MessageService.Messages.delete_message(%{
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
           MessageService.Messages.delete_message(%{
             "conversation_id" => conversation_id,
             "message_id" => message_id,
             "actor_user_id" => session.user_id
           }) do
      json(conn, response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
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
           MessageService.Receipts.mark_read(%{
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
         {:ok, response} <-
           MessageService.Receipts.mark_read(%{
             "conversation_id" => conversation_id,
             "message_id" => message_id,
             "user_id" => session.user_id
           }) do
      json(conn, response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
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
           MessageService.Receipts.mark_delivered(%{
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
           MessageService.Receipts.mark_delivered(%{
             "conversation_id" => conversation_id,
             "message_id" => message_id,
             "user_id" => session.user_id
           }) do
      json(conn, response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
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

  defp invalid_request(conn), do: ErrorResponse.invalid_request(conn, "message.invalid_request")

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
    case ConversationService.Conversations.get_conversation(%{
           "conversation_id" => conversation_id,
           "user_id" => user_id
         }) do
      {:ok, _conversation} -> :ok
      _ -> {:error, :conversation_membership_forbidden}
    end
  end

  defp message_persistence_enabled? do
    Application.get_env(:message_service, :message_persistence, false) ||
      System.get_env("MESSAGE_DB_BACKED") in ["true", "1", "yes"]
  end
end
