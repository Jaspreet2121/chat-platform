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
  @callback inbox_rows(attrs()) :: result()
  @callback shares_conversation?(attrs()) :: result()
  @callback get_conversation(attrs()) :: result()
  @callback add_participant(attrs()) :: result()
  @callback remove_participant(attrs()) :: result()
  # Voluntary leave (078) — self-removal, distinct from the moderation remove path.
  @callback leave_conversation(attrs()) :: result()
  @callback get_conversation_app(attrs()) :: result()
  @callback clear_history(attrs()) :: result()
  @callback set_auto_delete(attrs()) :: result()
  @callback set_mute(attrs()) :: result()
  # Per-user inbox prefs (archive/pin) — same shape as set_mute; set_pin may return {:error, :pin_limit}.
  @callback set_archive(attrs()) :: result()
  @callback set_pin(attrs()) :: result()
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
  @callback get_ongoing_group_call(attrs()) :: result()
  # Phase-3 C2 — add a participant to a live call + the token/join authorization predicate.
  @callback add_call_participant(attrs()) :: result()
  @callback call_participant?(attrs()) :: result()
  # Phase-3 C3b — promote a live 1-on-1 (direct) call to a group call.
  @callback promote_direct_to_group(attrs()) :: result()
  # Call links (L1) — reusable link → conversation-less "link" call.
  @callback create_call_link(attrs()) :: result()
  @callback get_call_link(attrs()) :: result()
  @callback join_call_link(attrs()) :: result()

  # Broadcast lists (081) — a user-owned recipient set (NOT a conversation); send is gateway orchestration.
  @callback create_broadcast_list(attrs()) :: result()
  @callback list_broadcast_lists(attrs()) :: result()
  @callback get_broadcast_list(attrs()) :: result()
  @callback update_broadcast_list(attrs()) :: result()
  @callback delete_broadcast_list(attrs()) :: result()

  # Group invite links (077) — shareable "join a group via link".
  @callback create_group_invite_link(attrs()) :: result()
  @callback revoke_group_invite_link(attrs()) :: result()
  @callback reset_group_invite_link(attrs()) :: result()
  @callback preview_group_invite_link(attrs()) :: result()
  @callback join_group_invite_link(attrs()) :: result()
  # Call links (L3a) — host approve/deny a pending joiner.
  @callback approve_link_participant(attrs()) :: result()
  @callback deny_link_participant(attrs()) :: result()

  # User blocking (safety). block/unblock/list back the first-party management endpoints; either_blocked? is
  # the symmetric hot-path check (messages/calls/presence/profile); direct_peer_blocked? gates a DIRECT
  # conversation's typing/viewing + the message drop.
  @callback block_user(attrs()) :: result()
  @callback unblock_user(attrs()) :: result()
  @callback list_blocks(attrs()) :: result()
  @callback either_blocked?(attrs()) :: result()
  @callback direct_peer_blocked?(attrs()) :: result()

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
                      get_call_with_participants: 1,
                      get_ongoing_group_call: 1,
                      add_call_participant: 1,
                      call_participant?: 1,
                      promote_direct_to_group: 1,
                      create_call_link: 1,
                      get_call_link: 1,
                      join_call_link: 1,
                      create_group_invite_link: 1,
                      revoke_group_invite_link: 1,
                      reset_group_invite_link: 1,
                      preview_group_invite_link: 1,
                      join_group_invite_link: 1,
                      approve_link_participant: 1,
                      deny_link_participant: 1,
                      block_user: 1,
                      unblock_user: 1,
                      list_blocks: 1,
                      either_blocked?: 1,
                      direct_peer_blocked?: 1,
                      set_archive: 1,
                      set_pin: 1,
                      leave_conversation: 1,
                      create_broadcast_list: 1,
                      list_broadcast_lists: 1,
                      get_broadcast_list: 1,
                      update_broadcast_list: 1,
                      delete_broadcast_list: 1

  def create_conversation(attrs), do: adapter().create_conversation(attrs)
  def list_conversations(attrs), do: adapter().list_conversations(attrs)

  @doc """
  The inbox row for ONE conversation as seen by EACH of `user_ids` — one round-trip for a whole fan-out.
  Each row carries that user's OWN unread_count/preview/updated_at (all three are per-participant; see
  ConversationService.Conversations.inbox_rows/1). Powers the `conversation_updated` broadcast.
  """
  def inbox_rows(attrs), do: adapter().inbox_rows(attrs)

  @doc "Do two users share an active conversation? (the presence 'contacts' edge). %{shares: bool}."
  def shares_conversation?(attrs), do: adapter().shares_conversation?(attrs)
  def admin_list_conversations(attrs), do: adapter().admin_list_conversations(attrs)
  def admin_user_conversations(attrs), do: adapter().admin_user_conversations(attrs)
  def get_conversation(attrs), do: adapter().get_conversation(attrs)
  def add_participant(attrs), do: adapter().add_participant(attrs)
  def remove_participant(attrs), do: adapter().remove_participant(attrs)
  def leave_conversation(attrs), do: adapter().leave_conversation(attrs)
  def get_conversation_app(attrs), do: adapter().get_conversation_app(attrs)
  def clear_history(attrs), do: adapter().clear_history(attrs)
  def set_auto_delete(attrs), do: adapter().set_auto_delete(attrs)
  def set_mute(attrs), do: adapter().set_mute(attrs)
  def set_archive(attrs), do: adapter().set_archive(attrs)
  def set_pin(attrs), do: adapter().set_pin(attrs)
  def set_group_profile(attrs), do: adapter().set_group_profile(attrs)
  def set_participant_role(attrs), do: adapter().set_participant_role(attrs)
  def set_group_settings(attrs), do: adapter().set_group_settings(attrs)
  def authorize_send(attrs), do: adapter().authorize_send(attrs)

  @doc "Block/unblock/list — the first-party block management endpoints. %{blocker_user_id, blocked_user_id}."
  def block_user(attrs), do: adapter().block_user(attrs)
  def unblock_user(attrs), do: adapter().unblock_user(attrs)
  def list_blocks(attrs), do: adapter().list_blocks(attrs)

  @doc "Symmetric either-direction block check (%{user_a, user_b} → %{blocked}). Messages/calls/presence/profile."
  def either_blocked?(attrs), do: adapter().either_blocked?(attrs)

  @doc "Is `user_id`'s DIRECT peer in `conversation_id` blocked? (%{conversation_id, user_id} → %{blocked})."
  def direct_peer_blocked?(attrs), do: adapter().direct_peer_blocked?(attrs)

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
  def get_ongoing_group_call(attrs), do: adapter().get_ongoing_group_call(attrs)
  def add_call_participant(attrs), do: adapter().add_call_participant(attrs)
  def call_participant?(attrs), do: adapter().call_participant?(attrs)
  def promote_direct_to_group(attrs), do: adapter().promote_direct_to_group(attrs)
  def create_call_link(attrs), do: adapter().create_call_link(attrs)
  def get_call_link(attrs), do: adapter().get_call_link(attrs)
  def join_call_link(attrs), do: adapter().join_call_link(attrs)

  def create_group_invite_link(attrs), do: adapter().create_group_invite_link(attrs)
  def revoke_group_invite_link(attrs), do: adapter().revoke_group_invite_link(attrs)
  def reset_group_invite_link(attrs), do: adapter().reset_group_invite_link(attrs)
  def preview_group_invite_link(attrs), do: adapter().preview_group_invite_link(attrs)
  def join_group_invite_link(attrs), do: adapter().join_group_invite_link(attrs)

  def create_broadcast_list(attrs), do: adapter().create_broadcast_list(attrs)
  def list_broadcast_lists(attrs), do: adapter().list_broadcast_lists(attrs)
  def get_broadcast_list(attrs), do: adapter().get_broadcast_list(attrs)
  def update_broadcast_list(attrs), do: adapter().update_broadcast_list(attrs)
  def delete_broadcast_list(attrs), do: adapter().delete_broadcast_list(attrs)
  def approve_link_participant(attrs), do: adapter().approve_link_participant(attrs)
  def deny_link_participant(attrs), do: adapter().deny_link_participant(attrs)

  @doc "The configured Conversation client adapter (default `ConversationService.ConversationClientInProcess`)."
  def adapter do
    Application.get_env(
      :shared_infra,
      :conversation_client_adapter,
      ConversationService.ConversationClientInProcess
    )
  end
end
