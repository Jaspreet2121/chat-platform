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

  WHAT IS DELIBERATELY *NOT* HERE: edits, deletes and receipts. Those are conversation-topic only on
  purpose (see V1.MessageController.fan_out_mutation/3) — the SDK routes both topics into one channel
  and, unlike `message_created`, they are not de-duplicated by id, so mirroring them would deliver
  each twice to anyone watching the conversation. Duplicate suppression is a property of the EVENT,
  not of the transport, and only events that carry it belong in here.
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
