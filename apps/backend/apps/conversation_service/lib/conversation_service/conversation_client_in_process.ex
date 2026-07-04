defmodule ConversationService.ConversationClientInProcess do
  @moduledoc """
  In-process adapter for `SharedInfra.ConversationClient` — the default. Delegates straight to
  the existing `ConversationService.{Conversations,Participants}` functions, returning the SAME
  shapes, so routing edge apps through the client boundary is a zero-behavior-change refactor.
  A future HTTP adapter (separate conversation-service container) implements the same behaviour.
  """

  @behaviour SharedInfra.ConversationClient

  alias ConversationService.Conversations
  alias ConversationService.Participants

  @impl true
  def create_conversation(attrs), do: Conversations.create_conversation(attrs)

  @impl true
  def list_conversations(attrs), do: Conversations.list_conversations(attrs)

  @impl true
  def admin_list_conversations(attrs), do: Conversations.admin_list_conversations(attrs)

  @impl true
  def admin_user_conversations(attrs), do: Conversations.admin_user_conversations(attrs)

  @impl true
  def get_conversation(attrs), do: Conversations.get_conversation(attrs)

  @impl true
  def get_conversation_app(attrs), do: Conversations.get_conversation_app(attrs)

  @impl true
  def get_call_conversation(attrs), do: Conversations.get_call_conversation(attrs)

  @impl true
  def add_participant(attrs), do: Participants.add_participant(attrs)

  @impl true
  def remove_participant(attrs), do: Participants.remove_participant(attrs)

  @impl true
  def clear_history(attrs), do: Participants.clear_history(attrs)

  @impl true
  def set_auto_delete(attrs), do: Participants.set_auto_delete(attrs)

  @impl true
  def set_mute(attrs), do: Participants.set_mute(attrs)
end
