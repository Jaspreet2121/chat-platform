defmodule SharedInfra.ConversationClient do
  @moduledoc """
  Client boundary for the Conversation service — lets edge apps (api_gateway,
  realtime_gateway) stop calling `ConversationService.*` in-process directly.

  Same pattern as `SharedInfra.AuthClient` / `SharedInfra.Kafka.Producer`: behaviour AND
  configured dispatcher. The adapter is selected from `:shared_infra, :conversation_client_adapter`
  (config default `ConversationService.ConversationClientInProcess`, which delegates in-process
  → zero behavior change). A future `CONVERSATION_CLIENT_ADAPTER=http` selects an HTTP adapter
  (separate conversation-service container) WITHOUT touching call sites.

  shared_infra does NOT compile-depend on conversation_service: the adapter module is resolved
  from config at runtime, so the base lib stays free of a service dependency.
  """

  @type attrs :: map()
  @type result :: {:ok, map()} | {:error, term()}

  @callback create_conversation(attrs()) :: result()
  @callback list_conversations(attrs()) :: result()
  @callback get_conversation(attrs()) :: result()
  @callback add_participant(attrs()) :: result()
  @callback remove_participant(attrs()) :: result()
  @callback get_conversation_app(attrs()) :: result()
  @callback clear_history(attrs()) :: result()
  @callback set_auto_delete(attrs()) :: result()
  @callback set_mute(attrs()) :: result()
  @callback set_group_profile(attrs()) :: result()
  @callback set_participant_role(attrs()) :: result()
  @callback set_group_settings(attrs()) :: result()
  @callback authorize_send(attrs()) :: result()
  @callback get_call_conversation(attrs()) :: result()
  @callback admin_list_conversations(attrs()) :: result()
  @callback admin_user_conversations(attrs()) :: result()
  # Phase-1 calling — call lifecycle + history (CallStore).
  @callback create_call(attrs()) :: result()
  @callback mark_call_answered(attrs()) :: result()
  @callback mark_call_declined(attrs()) :: result()
  @callback mark_call_missed(attrs()) :: result()
  @callback mark_call_ended(attrs()) :: result()
  @callback get_call(attrs()) :: result()
  @callback list_calls_for_user(attrs()) :: result()
  # Phase-3 group calling — group lifecycle (CallStore).
  @callback create_group_call(attrs()) :: result()
  @callback join_group_call(attrs()) :: result()
  @callback decline_group_call(attrs()) :: result()
  @callback leave_group_call(attrs()) :: result()
  @callback mark_group_participants_missed(attrs()) :: result()
  @callback get_call_with_participants(attrs()) :: result()

  # Optional so existing test stubs of this behaviour don't all need it; the real adapters implement it.
  @optional_callbacks get_conversation_app: 1,
                      get_call_conversation: 1,
                      admin_list_conversations: 1,
                      admin_user_conversations: 1,
                      create_call: 1,
                      mark_call_answered: 1,
                      mark_call_declined: 1,
                      mark_call_missed: 1,
                      mark_call_ended: 1,
                      get_call: 1,
                      list_calls_for_user: 1,
                      create_group_call: 1,
                      join_group_call: 1,
                      decline_group_call: 1,
                      leave_group_call: 1,
                      mark_group_participants_missed: 1,
                      get_call_with_participants: 1

  def create_conversation(attrs), do: adapter().create_conversation(attrs)
  def list_conversations(attrs), do: adapter().list_conversations(attrs)
  def admin_list_conversations(attrs), do: adapter().admin_list_conversations(attrs)
  def admin_user_conversations(attrs), do: adapter().admin_user_conversations(attrs)
  def get_conversation(attrs), do: adapter().get_conversation(attrs)
  def add_participant(attrs), do: adapter().add_participant(attrs)
  def remove_participant(attrs), do: adapter().remove_participant(attrs)
  def get_conversation_app(attrs), do: adapter().get_conversation_app(attrs)
  def clear_history(attrs), do: adapter().clear_history(attrs)
  def set_auto_delete(attrs), do: adapter().set_auto_delete(attrs)
  def set_mute(attrs), do: adapter().set_mute(attrs)
  def set_group_profile(attrs), do: adapter().set_group_profile(attrs)
  def set_participant_role(attrs), do: adapter().set_participant_role(attrs)
  def set_group_settings(attrs), do: adapter().set_group_settings(attrs)
  def authorize_send(attrs), do: adapter().authorize_send(attrs)
  def get_call_conversation(attrs), do: adapter().get_call_conversation(attrs)
  def create_call(attrs), do: adapter().create_call(attrs)
  def mark_call_answered(attrs), do: adapter().mark_call_answered(attrs)
  def mark_call_declined(attrs), do: adapter().mark_call_declined(attrs)
  def mark_call_missed(attrs), do: adapter().mark_call_missed(attrs)
  def mark_call_ended(attrs), do: adapter().mark_call_ended(attrs)
  def get_call(attrs), do: adapter().get_call(attrs)
  def list_calls_for_user(attrs), do: adapter().list_calls_for_user(attrs)
  def create_group_call(attrs), do: adapter().create_group_call(attrs)
  def join_group_call(attrs), do: adapter().join_group_call(attrs)
  def decline_group_call(attrs), do: adapter().decline_group_call(attrs)
  def leave_group_call(attrs), do: adapter().leave_group_call(attrs)
  def mark_group_participants_missed(attrs), do: adapter().mark_group_participants_missed(attrs)
  def get_call_with_participants(attrs), do: adapter().get_call_with_participants(attrs)

  @doc "The configured Conversation client adapter (default `ConversationService.ConversationClientInProcess`)."
  def adapter do
    Application.get_env(
      :shared_infra,
      :conversation_client_adapter,
      ConversationService.ConversationClientInProcess
    )
  end
end
