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
      json(conn, response)
    else
      {:error, :session_invalid} -> session_invalid(conn)
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
      json(conn, response)
    else
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :conversation_invalid} -> invalid_request(conn)
      {:error, :conversation_not_found} -> invalid_request(conn)
      {:error, :conversation_forbidden} -> invalid_request(conn)
      _ -> invalid_request(conn)
    end
  end

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
