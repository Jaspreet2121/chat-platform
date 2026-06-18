defmodule RealtimeGateway.TopicAuthorization do
  @moduledoc """
  Join authorization boundary for realtime topics.

  Conversation membership checks are feature-gated behind Conversation Service
  persistence. Tenant access and block-list checks remain future work.
  """

  def authorize_join("conversation:" <> conversation_id, socket) do
    if conversation_persistence_enabled?() do
      authorize_conversation_join(conversation_id, socket)
    else
      :ok
    end
  end

  def authorize_join(_topic, _socket), do: :ok

  defp authorize_conversation_join(conversation_id, socket) do
    with {:ok, user_id} <- socket_user_id(socket),
         {:ok, _conversation} <-
           SharedInfra.ConversationClient.get_conversation(%{
             "conversation_id" => conversation_id,
             "user_id" => user_id
           }) do
      :ok
    else
      {:error, :missing_user} ->
        {:error, %{code: "realtime.unauthorized", message: "Missing or invalid socket user"}}

      {:error, reason}
      when reason in [
             :conversation_forbidden,
             :conversation_not_found,
             :conversation_invalid
           ] ->
        {:error, %{code: "realtime.forbidden", message: "Conversation join is forbidden"}}
    end
  rescue
    _error ->
      {:error, %{code: "realtime.internal_error", message: "Realtime authorization failed"}}
  end

  defp socket_user_id(socket) do
    user_id = Map.get(socket.assigns, :user_id) || Map.get(socket.assigns, :current_user_id)

    case user_id do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_user}
    end
  end

  defp conversation_persistence_enabled? do
    Application.get_env(:conversation_service, :conversation_persistence, false) ||
      System.get_env("CONVERSATION_DB_BACKED") in ["true", "1", "yes"]
  end
end
