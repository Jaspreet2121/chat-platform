defmodule ApiGatewayWeb.EncryptionController do
  @moduledoc """
  Secret-chat toggle (108): POST /api/v1/conversations/:id/encryption {"enabled": true}. 1:1 only,
  member-only, both sides must hold device keys (107), and ONE-WAY — see the store
  (ConversationService.Encryption) for the recorded decisions. On enable: a plaintext SYSTEM
  message {kind: "encryption", state: "enabled"} through the normal message path (system messages
  in a secret chat carry protocol state, never user content — plaintext by design) + a
  conversation_encryption_changed broadcast to both members.
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse
  alias ApiGatewayWeb.SecretChatEvents

  def update(conn, %{"conversation_id" => conversation_id} = params) do
    with {:ok, session} <- session(conn),
         {:ok, result} <-
           SharedInfra.ConversationClient.set_encryption(%{
             "conversation_id" => conversation_id,
             "user_id" => session.user_id,
             "enabled" => Map.get(params, "enabled")
           }) do
      already = mget(result, :already) == true
      members = mget(result, :member_ids) || []

      unless already do
        SecretChatEvents.system_message(conversation_id, session.user_id, %{
          "kind" => "encryption",
          "state" => "enabled",
          "by" => session.user_id
        })

        for member <- members do
          ApiGatewayWeb.Endpoint.broadcast(
            "user:" <> member,
            "conversation_encryption_changed",
            %{
              "type" => "conversation_encryption_changed",
              "conversation_id" => conversation_id,
              "enabled" => true
            }
          )
        end
      end

      json(conn, %{enabled: true})
    else
      error -> handle_error(conn, error)
    end
  end

  def update(conn, _params), do: ErrorResponse.invalid_request(conn, "secret.invalid")

  defp session(conn) do
    with ["Bearer " <> token] when token != "" <- get_req_header(conn, "authorization"),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => "Bearer " <> token}) do
      {:ok, session}
    else
      _ -> {:error, :session_invalid}
    end
  end

  defp handle_error(conn, {:error, :session_invalid}),
    do: ErrorResponse.unauthorized(conn, "auth.session_invalid", "Invalid or expired session")

  defp handle_error(conn, {:error, :secret_not_supported}),
    do:
      ErrorResponse.unprocessable_entity(
        conn,
        "secret.not_supported",
        "Secret chats are 1:1 only"
      )

  defp handle_error(conn, {:error, :secret_cannot_disable}),
    do:
      ErrorResponse.unprocessable_entity(
        conn,
        "secret.cannot_disable",
        "A secret chat cannot be switched back — start a new chat instead"
      )

  defp handle_error(conn, {:error, {:secret_peer_keys_missing, missing}}) do
    ErrorResponse.conflict_with(
      conn,
      "secret.peer_keys_missing",
      "Both sides need registered device keys first",
      %{missing_user_ids: missing}
    )
  end

  defp handle_error(conn, {:error, :conversation_not_found}),
    do: ErrorResponse.not_found(conn, "conversation.not_found", "Conversation not found")

  defp handle_error(conn, {:error, :conversation_unavailable}),
    do: ErrorResponse.service_unavailable(conn, "secret.unavailable")

  defp handle_error(conn, _), do: ErrorResponse.invalid_request(conn, "secret.invalid")

  defp mget(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp mget(_, _), do: nil
end
