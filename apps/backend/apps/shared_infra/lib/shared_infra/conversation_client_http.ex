defmodule SharedInfra.ConversationClientHttp do
  @moduledoc """
  HTTP adapter for `SharedInfra.ConversationClient` — calls conversation-service's internal HTTP API
  (`ConversationService.HTTP.Router`) over the network. Selected by `CONVERSATION_CLIENT_ADAPTER=http`;
  default stays `ConversationService.ConversationClientInProcess` (zero behavior change until flipped).

  Same template as `SharedInfra.AuthClientHttp`: lives in shared_infra (not conversation_service);
  shapes reconstructed via `SharedInfra.InternalApi.decode_result/1` through `SharedInfra.HttpClient`
  (atom-keyed conversation/participant maps + nested participant lists round-trip via the recursive
  decoder; error atoms preserved). Transport failure → `{:error, :conversation_unavailable}` (gateway/
  realtime map that to 503 / a realtime-unavailable error). Base URL from `CONVERSATION_SERVICE_URL`.
  """

  @behaviour SharedInfra.ConversationClient

  @unavailable :conversation_unavailable

  @impl true
  def create_conversation(attrs), do: post("/internal/conversations/create", attrs)

  @impl true
  def list_conversations(attrs), do: post("/internal/conversations/list", attrs)

  @impl true
  def admin_list_conversations(attrs), do: post("/internal/conversations/admin_list", attrs)

  @impl true
  def admin_user_conversations(attrs), do: post("/internal/conversations/admin_user", attrs)

  @impl true
  def get_conversation(attrs), do: post("/internal/conversations/get", attrs)

  @impl true
  def get_conversation_app(attrs), do: post("/internal/conversations/get_app", attrs)

  @impl true
  def get_call_conversation(attrs), do: post("/internal/conversations/call_conversation", attrs)

  @impl true
  def add_participant(attrs), do: post("/internal/participants/add", attrs)

  @impl true
  def remove_participant(attrs), do: post("/internal/participants/remove", attrs)

  @impl true
  def clear_history(attrs), do: post("/internal/participants/clear_history", attrs)

  @impl true
  def set_auto_delete(attrs), do: post("/internal/participants/set_auto_delete", attrs)

  defp post(path, attrs) do
    SharedInfra.HttpClient.post_result(base_url(), path, attrs, unavailable: @unavailable)
  end

  defp base_url do
    Application.get_env(:shared_infra, :conversation_service_url) ||
      System.get_env("CONVERSATION_SERVICE_URL") || "http://localhost:4102"
  end
end
