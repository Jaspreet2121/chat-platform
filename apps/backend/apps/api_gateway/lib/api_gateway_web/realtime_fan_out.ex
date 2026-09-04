defmodule ApiGatewayWeb.RealtimeFanOut do
  @moduledoc """
  THE TWO-TOPIC RULE, in one place.

  Clients join `conversation:<id>` ONLY for the chat they currently have open — joining every
  conversation would falsely mark them present ("Active now") everywhere, which is why
  ConversationChannel deliberately does not. The consequence is easy to forget and has now cost two
  live bugs: **a conversation-topic broadcast reaches only the people looking at that chat.** Anything
  a user needs while the chat is closed must ALSO go to their `user:<id>` topic.

  The socket path and the `/v1` REST path already did both. The first-party REST paths did not, so an
  Android-sent DM produced no live message at all and `view_once_opened` never reached the sender —
  the one participant guaranteed NOT to have the chat open.

  TWO SHAPES, ONE MODULE. `to_participants/4` mirrors an event onto BOTH topics — safe only for
  events de-duplicated by id (`message_created`, `view_once_opened`). `to_conversation/3` broadcasts
  to the conversation topic ONLY — the required shape for edits, deletes, reactions and receipts: the
  SDK routes both topics into one channel and those events are NOT de-duplicated, so mirroring them
  would deliver each twice to anyone watching the conversation. Duplicate suppression is a property
  of the EVENT, not of the transport, and which helper an event uses is exactly that property.
  """

  @doc """
  Mirror an event onto the conversation topic AND every participant's user topic except `actor_id`.

  Fire-and-forget in a Task: a fan-out must never fail or slow the request that caused it.
  """
  def to_participants(conversation_id, actor_id, event, payload) do
    Task.start(fn ->
      try do
        ApiGatewayWeb.Endpoint.broadcast("conversation:" <> conversation_id, event, payload)

        conversation_id
        |> participants_except(actor_id)
        |> Enum.each(&ApiGatewayWeb.Endpoint.broadcast("user:" <> &1, event, payload))
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  @doc """
  Broadcast an event to the CONVERSATION topic only — the mutation shape.

  For `message_updated` / `message_deleted` / `reaction_updated` / `receipt_updated`: same semantics
  as the socket path's `broadcast_from` and `/v1`'s `fan_out_mutation/3` (which delegates here), and
  deliberately NEVER mirrored to `user:<id>` — see the moduledoc. A recipient with the chat closed
  learns of the change on their next open/refetch, which is the accepted cost of not double-rendering
  for everyone with it open.

  Fire-and-forget in a Task: a fan-out must never fail or slow the request that caused it.
  """
  def to_conversation(conversation_id, event, payload) do
    Task.start(fn ->
      try do
        ApiGatewayWeb.Endpoint.broadcast("conversation:" <> conversation_id, event, payload)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  @doc """
  The participants of a conversation, minus `actor_id` (and any nil).

  Reads through ConversationClient with the ACTOR as the viewer, so a non-participant caller resolves
  nothing and fans out to nobody — the membership check the caller already passed is what makes this
  safe to call.
  """
  def participants_except(conversation_id, actor_id) do
    case SharedInfra.ConversationClient.get_conversation(%{
           "conversation_id" => conversation_id,
           "user_id" => actor_id
         }) do
      {:ok, conversation} ->
        (Map.get(conversation, :participants) || Map.get(conversation, "participants") || [])
        |> Enum.map(fn p -> Map.get(p, :user_id) || Map.get(p, "user_id") end)
        |> Enum.reject(&(&1 in [nil, actor_id]))

      _ ->
        []
    end
  end
end
