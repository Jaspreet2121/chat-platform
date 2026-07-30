defmodule ConversationService.HTTP.Router do
  @moduledoc """
  Internal HTTP API for conversation-service (Plug, not Phoenix). Routes map 1:1 to
  `SharedInfra.ConversationClient`'s contract; each calls the in-process
  `ConversationService.{Conversations,Participants}` function and serializes via
  `SharedInfra.InternalApi.encode_result/1` (preserving error atoms — e.g. `:conversation_forbidden`,
  `:participant_invalid` — that the gateway pattern-matches on). Same template as
  `AuthService.HTTP.Router`. Transport auth via `SharedInfra.InternalApi.TokenPlug`.

  Started ONLY under `CONVERSATION_HTTP_API_ENABLED` (see `ConversationService.Application`),
  default off → no listener at boot. See docs/09-devops/INTERNAL_API.md.
  """
  use Plug.Router

  plug(SharedInfra.InternalApi.TokenPlug)
  plug(SharedInfra.InternalApi.CorrelationPlug)
  plug(:match)
  plug(Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
  plug(:dispatch)

  post "/internal/conversations/create" do
    send_result(conn, ConversationService.Conversations.create_conversation(body(conn)))
  end

  post "/internal/conversations/list" do
    send_result(conn, ConversationService.Conversations.list_conversations(body(conn)))
  end

  post "/internal/conversations/admin_list" do
    send_result(conn, ConversationService.Conversations.admin_list_conversations(body(conn)))
  end

  post "/internal/conversations/admin_user" do
    send_result(conn, ConversationService.Conversations.admin_user_conversations(body(conn)))
  end

  post "/internal/conversations/inbox_rows" do
    send_result(conn, ConversationService.Conversations.inbox_rows(body(conn)))
  end

  post "/internal/conversations/shares" do
    send_result(conn, ConversationService.Conversations.shares_conversation?(body(conn)))
  end

  post "/internal/conversations/get" do
    send_result(conn, ConversationService.Conversations.get_conversation(body(conn)))
  end

  post "/internal/conversations/get_app" do
    send_result(conn, ConversationService.Conversations.get_conversation_app(body(conn)))
  end

  post "/internal/conversations/call_conversation" do
    send_result(conn, ConversationService.Conversations.get_call_conversation(body(conn)))
  end

  post "/internal/participants/add" do
    send_result(conn, ConversationService.Participants.add_participant(body(conn)))
  end

  post "/internal/participants/clear_history" do
    send_result(conn, ConversationService.Participants.clear_history(body(conn)))
  end

  post "/internal/participants/set_auto_delete" do
    send_result(conn, ConversationService.Participants.set_auto_delete(body(conn)))
  end

  post "/internal/participants/set_mute" do
    send_result(conn, ConversationService.Participants.set_mute(body(conn)))
  end

  post "/internal/participants/set_archive" do
    send_result(conn, ConversationService.Participants.set_archive(body(conn)))
  end

  post "/internal/participants/set_pin" do
    send_result(conn, ConversationService.Participants.set_pin(body(conn)))
  end

  post "/internal/conversations/set_group_profile" do
    send_result(conn, ConversationService.Conversations.set_group_profile(body(conn)))
  end

  post "/internal/participants/set_role" do
    send_result(conn, ConversationService.Participants.set_participant_role(body(conn)))
  end

  post "/internal/conversations/set_group_settings" do
    send_result(conn, ConversationService.Participants.set_group_settings(body(conn)))
  end

  post "/internal/conversations/authorize_send" do
    send_result(conn, ConversationService.Participants.authorize_send(body(conn)))
  end

  post "/internal/participants/remove" do
    send_result(conn, ConversationService.Participants.remove_participant(body(conn)))
  end

  # Voluntary leave (078) — self-removal, distinct from the moderation remove path above.
  post "/internal/participants/leave" do
    send_result(conn, ConversationService.Participants.leave_conversation(body(conn)))
  end

  # Phase-1 calling — call lifecycle + history (CallStore).
  post "/internal/calls/create" do
    send_result(conn, ConversationService.CallStore.create_call(body(conn)))
  end

  post "/internal/calls/answer" do
    send_result(conn, ConversationService.CallStore.mark_answered(body(conn)))
  end

  post "/internal/calls/decline" do
    send_result(conn, ConversationService.CallStore.mark_declined(body(conn)))
  end

  post "/internal/calls/miss" do
    send_result(conn, ConversationService.CallStore.mark_missed(body(conn)))
  end

  post "/internal/calls/end" do
    send_result(conn, ConversationService.CallStore.mark_ended(body(conn)))
  end

  post "/internal/calls/get" do
    send_result(conn, ConversationService.CallStore.get_call(body(conn)))
  end

  post "/internal/calls/list" do
    send_result(conn, ConversationService.CallStore.list_calls_for_user(body(conn)))
  end

  # Phase-3 group calling — group lifecycle (CallStore).
  post "/internal/calls/group/create" do
    send_result(conn, ConversationService.CallStore.create_group_call(body(conn)))
  end

  post "/internal/calls/group/join" do
    send_result(conn, ConversationService.CallStore.join_group_call(body(conn)))
  end

  post "/internal/calls/group/decline" do
    send_result(conn, ConversationService.CallStore.decline_group_call(body(conn)))
  end

  post "/internal/calls/group/leave" do
    send_result(conn, ConversationService.CallStore.leave_group_call(body(conn)))
  end

  post "/internal/calls/group/miss" do
    send_result(conn, ConversationService.CallStore.mark_group_participants_missed(body(conn)))
  end

  post "/internal/calls/group/get" do
    send_result(conn, ConversationService.CallStore.get_call_with_participants(body(conn)))
  end

  post "/internal/calls/group/ongoing" do
    send_result(conn, ConversationService.CallStore.get_ongoing_group_call(body(conn)))
  end

  post "/internal/calls/group/add" do
    send_result(conn, ConversationService.CallStore.add_call_participant(body(conn)))
  end

  post "/internal/calls/participant-check" do
    send_result(conn, ConversationService.CallStore.call_participant?(body(conn)))
  end

  post "/internal/calls/promote" do
    send_result(conn, ConversationService.CallStore.promote_direct_to_group(body(conn)))
  end

  # Call links (L1).
  post "/internal/call-links/create" do
    send_result(conn, ConversationService.CallStore.create_call_link(body(conn)))
  end

  post "/internal/call-links/get" do
    send_result(conn, ConversationService.CallStore.get_call_link(body(conn)))
  end

  post "/internal/call-links/join" do
    send_result(conn, ConversationService.CallStore.join_call_link(body(conn)))
  end

  post "/internal/call-links/approve" do
    send_result(conn, ConversationService.CallStore.approve_link_participant(body(conn)))
  end

  post "/internal/call-links/deny" do
    send_result(conn, ConversationService.CallStore.deny_link_participant(body(conn)))
  end

  # Group invite links (077) — shareable "join a group via link".
  post "/internal/invite-links/create" do
    send_result(conn, ConversationService.InviteLinks.create_link(body(conn)))
  end

  post "/internal/invite-links/revoke" do
    send_result(conn, ConversationService.InviteLinks.revoke_link(body(conn)))
  end

  post "/internal/invite-links/reset" do
    send_result(conn, ConversationService.InviteLinks.reset_link(body(conn)))
  end

  post "/internal/invite-links/preview" do
    send_result(conn, ConversationService.InviteLinks.preview_link(body(conn)))
  end

  post "/internal/invite-links/join" do
    send_result(conn, ConversationService.InviteLinks.join_link(body(conn)))
  end

  post "/internal/blocks/create" do
    send_result(conn, ConversationService.Blocks.block(body(conn)))
  end

  post "/internal/blocks/delete" do
    send_result(conn, ConversationService.Blocks.unblock(body(conn)))
  end

  post "/internal/blocks/list" do
    send_result(conn, ConversationService.Blocks.list_blocks(body(conn)))
  end

  post "/internal/blocks/either" do
    send_result(conn, ConversationService.Blocks.either_blocked?(body(conn)))
  end

  post "/internal/blocks/direct_peer" do
    send_result(conn, ConversationService.Blocks.direct_peer_blocked?(body(conn)))
  end

  get "/internal/health" do
    send_result(conn, {:ok, %{service: "conversation", status: "ok", deps: %{}}})
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{"error" => "not_found"}))
  end

  defp body(%{body_params: params}) when is_map(params) and not is_struct(params), do: params
  defp body(_conn), do: %{}

  defp send_result(conn, result) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(SharedInfra.InternalApi.encode_result(result)))
  end
end
