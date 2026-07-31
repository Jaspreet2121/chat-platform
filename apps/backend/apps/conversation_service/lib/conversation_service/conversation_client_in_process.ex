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
  def inbox_rows(attrs), do: Conversations.inbox_rows(attrs)

  @impl true
  def shares_conversation?(attrs), do: Conversations.shares_conversation?(attrs)

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
  def leave_conversation(attrs), do: Participants.leave_conversation(attrs)

  @impl true
  def clear_history(attrs), do: Participants.clear_history(attrs)

  @impl true
  def set_auto_delete(attrs), do: Participants.set_auto_delete(attrs)

  @impl true
  def set_mute(attrs), do: Participants.set_mute(attrs)

  @impl true
  def set_archive(attrs), do: Participants.set_archive(attrs)

  @impl true
  def set_pin(attrs), do: Participants.set_pin(attrs)

  @impl true
  def set_group_profile(attrs), do: ConversationService.Conversations.set_group_profile(attrs)

  @impl true
  def set_participant_role(attrs),
    do: ConversationService.Participants.set_participant_role(attrs)

  @impl true
  def set_group_settings(attrs), do: ConversationService.Participants.set_group_settings(attrs)

  @impl true
  def authorize_send(attrs), do: ConversationService.Participants.authorize_send(attrs)

  @impl true
  def block_user(attrs), do: ConversationService.Blocks.block(attrs)

  @impl true
  def unblock_user(attrs), do: ConversationService.Blocks.unblock(attrs)

  @impl true
  def list_blocks(attrs), do: ConversationService.Blocks.list_blocks(attrs)

  @impl true
  def either_blocked?(attrs), do: ConversationService.Blocks.either_blocked?(attrs)

  @impl true
  def direct_peer_blocked?(attrs), do: ConversationService.Blocks.direct_peer_blocked?(attrs)

  @impl true
  def create_call(attrs), do: ConversationService.CallStore.create_call(attrs)

  @impl true
  def mark_call_answered(attrs), do: ConversationService.CallStore.mark_answered(attrs)

  @impl true
  def mark_call_declined(attrs), do: ConversationService.CallStore.mark_declined(attrs)

  @impl true
  def mark_call_missed(attrs), do: ConversationService.CallStore.mark_missed(attrs)

  @impl true
  def mark_call_ended(attrs), do: ConversationService.CallStore.mark_ended(attrs)

  @impl true
  def get_call(attrs), do: ConversationService.CallStore.get_call(attrs)

  @impl true
  def list_calls_for_user(attrs), do: ConversationService.CallStore.list_calls_for_user(attrs)

  @impl true
  def create_group_call(attrs), do: ConversationService.CallStore.create_group_call(attrs)

  @impl true
  def join_group_call(attrs), do: ConversationService.CallStore.join_group_call(attrs)

  @impl true
  def decline_group_call(attrs), do: ConversationService.CallStore.decline_group_call(attrs)

  @impl true
  def leave_group_call(attrs), do: ConversationService.CallStore.leave_group_call(attrs)

  @impl true
  def mark_group_participants_missed(attrs),
    do: ConversationService.CallStore.mark_group_participants_missed(attrs)

  @impl true
  def get_call_with_participants(attrs),
    do: ConversationService.CallStore.get_call_with_participants(attrs)

  @impl true
  def get_ongoing_group_call(attrs),
    do: ConversationService.CallStore.get_ongoing_group_call(attrs)

  @impl true
  def add_call_participant(attrs), do: ConversationService.CallStore.add_call_participant(attrs)

  @impl true
  def call_participant?(attrs), do: ConversationService.CallStore.call_participant?(attrs)

  @impl true
  def promote_direct_to_group(attrs),
    do: ConversationService.CallStore.promote_direct_to_group(attrs)

  @impl true
  def create_call_link(attrs), do: ConversationService.CallStore.create_call_link(attrs)

  @impl true
  def get_call_link(attrs), do: ConversationService.CallStore.get_call_link(attrs)

  @impl true
  def join_call_link(attrs), do: ConversationService.CallStore.join_call_link(attrs)

  @impl true
  def create_group_invite_link(attrs), do: ConversationService.InviteLinks.create_link(attrs)

  @impl true
  def revoke_group_invite_link(attrs), do: ConversationService.InviteLinks.revoke_link(attrs)

  @impl true
  def reset_group_invite_link(attrs), do: ConversationService.InviteLinks.reset_link(attrs)

  @impl true
  def preview_group_invite_link(attrs), do: ConversationService.InviteLinks.preview_link(attrs)

  @impl true
  def join_group_invite_link(attrs), do: ConversationService.InviteLinks.join_link(attrs)

  @impl true
  def create_broadcast_list(attrs), do: ConversationService.BroadcastLists.create_list(attrs)

  @impl true
  def list_broadcast_lists(attrs), do: ConversationService.BroadcastLists.list_lists(attrs)

  @impl true
  def get_broadcast_list(attrs), do: ConversationService.BroadcastLists.get_list(attrs)

  @impl true
  def update_broadcast_list(attrs), do: ConversationService.BroadcastLists.update_list(attrs)

  @impl true
  def delete_broadcast_list(attrs), do: ConversationService.BroadcastLists.delete_list(attrs)

  @impl true
  def approve_link_participant(attrs),
    do: ConversationService.CallStore.approve_link_participant(attrs)

  @impl true
  def deny_link_participant(attrs), do: ConversationService.CallStore.deny_link_participant(attrs)
end
