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
  def inbox_rows(attrs), do: post("/internal/conversations/inbox_rows", attrs)

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
  def create_call(attrs), do: post("/internal/calls/create", attrs)

  @impl true
  def mark_call_answered(attrs), do: post("/internal/calls/answer", attrs)

  @impl true
  def mark_call_declined(attrs), do: post("/internal/calls/decline", attrs)

  @impl true
  def mark_call_missed(attrs), do: post("/internal/calls/miss", attrs)

  @impl true
  def mark_call_ended(attrs), do: post("/internal/calls/end", attrs)

  @impl true
  def get_call(attrs), do: post("/internal/calls/get", attrs)

  @impl true
  def list_calls_for_user(attrs), do: post("/internal/calls/list", attrs)

  @impl true
  def create_group_call(attrs), do: post("/internal/calls/group/create", attrs)

  @impl true
  def join_group_call(attrs), do: post("/internal/calls/group/join", attrs)

  @impl true
  def decline_group_call(attrs), do: post("/internal/calls/group/decline", attrs)

  @impl true
  def leave_group_call(attrs), do: post("/internal/calls/group/leave", attrs)

  @impl true
  def mark_group_participants_missed(attrs), do: post("/internal/calls/group/miss", attrs)

  @impl true
  def get_call_with_participants(attrs), do: post("/internal/calls/group/get", attrs)

  @impl true
  def get_ongoing_group_call(attrs), do: post("/internal/calls/group/ongoing", attrs)

  @impl true
  def add_call_participant(attrs), do: post("/internal/calls/group/add", attrs)

  @impl true
  def call_participant?(attrs), do: post("/internal/calls/participant-check", attrs)

  @impl true
  def promote_direct_to_group(attrs), do: post("/internal/calls/promote", attrs)

  @impl true
  def create_call_link(attrs), do: post("/internal/call-links/create", attrs)

  @impl true
  def get_call_link(attrs), do: post("/internal/call-links/get", attrs)

  @impl true
  def join_call_link(attrs), do: post("/internal/call-links/join", attrs)

  @impl true
  def approve_link_participant(attrs), do: post("/internal/call-links/approve", attrs)

  @impl true
  def deny_link_participant(attrs), do: post("/internal/call-links/deny", attrs)

  @impl true
  def add_participant(attrs), do: post("/internal/participants/add", attrs)

  @impl true
  def remove_participant(attrs), do: post("/internal/participants/remove", attrs)

  @impl true
  def clear_history(attrs), do: post("/internal/participants/clear_history", attrs)

  @impl true
  def set_auto_delete(attrs), do: post("/internal/participants/set_auto_delete", attrs)

  @impl true
  def set_mute(attrs), do: post("/internal/participants/set_mute", attrs)

  @impl true
  def set_group_profile(attrs), do: post("/internal/conversations/set_group_profile", attrs)

  @impl true
  def set_participant_role(attrs), do: post("/internal/participants/set_role", attrs)

  @impl true
  def set_group_settings(attrs), do: post("/internal/conversations/set_group_settings", attrs)

  @impl true
  def authorize_send(attrs), do: post("/internal/conversations/authorize_send", attrs)

  defp post(path, attrs) do
    SharedInfra.HttpClient.post_result(base_url(), path, attrs, unavailable: @unavailable)
  end

  defp base_url do
    Application.get_env(:shared_infra, :conversation_service_url) ||
      System.get_env("CONVERSATION_SERVICE_URL") || "http://localhost:4102"
  end
end
