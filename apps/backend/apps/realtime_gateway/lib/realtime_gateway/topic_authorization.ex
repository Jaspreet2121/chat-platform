defmodule RealtimeGateway.TopicAuthorization do
  @moduledoc """
  Join authorization boundary for realtime topics.

  A conversation join is gated by TWO independent checks (both behind Conversation Service
  persistence): a TENANT check — the conversation must belong to the socket's app_id, resolved via the
  SAME scoped store fn the HTTP /v1 gate uses (get_conversation_app with app_id → the (app_id, id)
  predicate) — and a MEMBERSHIP check (the socket's user is an active participant). A cross-tenant or
  unknown id both reject as forbidden, never confirming another tenant's conversation exists.
  Block-list checks remain future work.
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
         :ok <- authorize_tenant(conversation_id, socket),
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

      # Conversation service unreachable over the network (HTTP adapter): reject the join with a
      # distinct unavailable signal rather than a forbidden/internal_error.
      {:error, :conversation_unavailable} ->
        {:error, %{code: "realtime.unavailable", message: "Conversation service is unavailable"}}
    end
  rescue
    _error ->
      {:error, %{code: "realtime.internal_error", message: "Realtime authorization failed"}}
  end

  # Authoritative TENANT gate: reuse the SAME scoped lookup the HTTP /v1 gate uses — pass the socket's
  # app_id INTO get_conversation_app so the conversation resolves ONLY within that app (the (app_id, id)
  # predicate in ConversationStore.get_conversation_in_app). A cross-tenant OR unknown id both come back
  # :conversation_not_found, so we never even load — let alone confirm the existence of — another
  # tenant's conversation. An App-A socket can never join an App-B topic.
  defp authorize_tenant(conversation_id, socket) do
    case SharedInfra.ConversationClient.get_conversation_app(%{
           "conversation_id" => conversation_id,
           "app_id" => Map.get(socket.assigns, :app_id)
         }) do
      {:ok, _conversation} ->
        :ok

      {:error, :conversation_unavailable} ->
        {:error, :conversation_unavailable}

      _ ->
        {:error, :conversation_not_found}
    end
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
