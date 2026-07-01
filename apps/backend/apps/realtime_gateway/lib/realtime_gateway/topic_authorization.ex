defmodule RealtimeGateway.TopicAuthorization do
  @moduledoc """
  Join authorization boundary for realtime topics.

  A conversation join is gated by TWO independent checks (both behind Conversation Service
  persistence): a TENANT check — the conversation must belong to the socket's app_id, resolved via the
  SAME scoped store fn the HTTP /v1 gate uses (get_conversation_app with app_id → the (app_id, id)
  predicate) — and a MEMBERSHIP check (the socket's user is an active participant). A cross-tenant or
  unknown id both reject as forbidden, never confirming another tenant's conversation exists.

  A CALL topic (`call:<call_session_id>`) is gated by its parent conversation (resolved via
  `call_sessions.conversation_id`) through the SAME conversation gate — so an App-B socket can never
  join App-A's call. A USER topic (`user:<user_id>`) is identity-pinned: a socket may only join its
  OWN user topic. Block-list checks remain future work.
  """

  def authorize_join("conversation:" <> conversation_id, socket) do
    if conversation_persistence_enabled?() do
      authorize_conversation_join(conversation_id, socket)
    else
      :ok
    end
  end

  # A call belongs to a conversation (call_sessions.conversation_id → conversations). Gate the call
  # topic by THAT conversation's tenant + membership — the SAME gate as the conversation topic, so an
  # App-B socket can never join App-A's call. Skeleton mode (persistence off) stays open, matching the
  # conversation clause.
  def authorize_join("call:" <> call_id, socket) do
    if conversation_persistence_enabled?() do
      authorize_call_join(call_id, socket)
    else
      :ok
    end
  end

  # Identity pin: a socket may ONLY join its OWN user topic. Tenant is implied by the user (an app's
  # end-users are distinct rows per app), and this blocks subscribing to another user's per-user topic.
  def authorize_join("user:" <> topic_user_id, socket) do
    case socket_user_id(socket) do
      {:ok, ^topic_user_id} ->
        :ok

      {:ok, _other_user} ->
        {:error, %{code: "realtime.forbidden", message: "User topic join is forbidden"}}

      {:error, :missing_user} ->
        {:error, %{code: "realtime.unauthorized", message: "Missing or invalid socket user"}}
    end
  end

  def authorize_join(_topic, _socket), do: :ok

  # Resolve the call → its conversation, then run the conversation tenant + membership gate on that id.
  # A cross-tenant / unknown / non-participant call all reject as realtime.forbidden — no reveal that
  # the call exists in another tenant.
  defp authorize_call_join(call_id, socket) do
    case SharedInfra.ConversationClient.get_call_conversation(%{"call_id" => call_id}) do
      {:ok, resolved} ->
        case call_conversation_id(resolved) do
          conversation_id when is_binary(conversation_id) and conversation_id != "" ->
            authorize_conversation_join(conversation_id, socket)

          _ ->
            {:error, %{code: "realtime.forbidden", message: "Call join is forbidden"}}
        end

      {:error, :conversation_unavailable} ->
        {:error, %{code: "realtime.unavailable", message: "Conversation service is unavailable"}}

      _ ->
        {:error, %{code: "realtime.forbidden", message: "Call join is forbidden"}}
    end
  rescue
    _error ->
      {:error, %{code: "realtime.internal_error", message: "Realtime authorization failed"}}
  end

  defp call_conversation_id(map) when is_map(map),
    do: Map.get(map, :conversation_id) || Map.get(map, "conversation_id")

  defp call_conversation_id(_), do: nil

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
