defmodule ApiGatewayWeb.ConversationBroadcast do
  @moduledoc """
  The gateway's inbox broadcasts: `conversation_created` (below) and `conversation_updated` (delegated to
  `SharedInfra.ConversationBroadcast`, which the realtime channel shares).

  Fan a freshly-created conversation onto each participant's `user:<id>` topic, so a client's inbox can
  live-update without a refetch. Shared by the `/v1` and first-party create controllers so the logic can't
  drift between them.

  Mirrors the message fan-out (`ApiGatewayWeb.V1.MessageController.notify_user_topics`): broadcast from the
  GATEWAY (sockets are mounted here; conversation_service can't reach them), fire-and-forget (`Task.start` +
  rescue — a broadcast hiccup must never fail the create response), to each participant EXCEPT the creator
  (the creator already has the conversation in the create response).

  Only `user:<id>` — a brand-new conversation has NO `conversation:<id>` subscribers yet (members haven't
  joined it). Only fires on a GENUINE insert: the create response carries `:created` (true = inserted,
  false = an idempotent direct returning an existing thread); a false/absent flag → NO broadcast.

  Payload = the inbox row `GET /v1/conversations` returns via `present_list`. A new conversation has no
  messages, so `last_message_preview`/`last_message_kind` are nil, `unread_count` is 0, and `updated_at`
  equals the conversation's `created_at`.
  """

  require Logger

  @doc "Broadcast conversation_created to non-creator participants iff the response is a genuine insert."
  def broadcast_created(response) when is_map(response) do
    if cget(response, :created) == true do
      created_by = cget(response, :created_by)
      participants = cget(response, :participant_user_ids) || []
      row = inbox_row(response)

      Task.start(fn ->
        try do
          participants
          |> Enum.reject(&(is_nil(&1) or &1 == "" or &1 == created_by))
          |> Enum.each(fn user_id ->
            ApiGatewayWeb.Endpoint.broadcast("user:" <> user_id, "conversation_created", row)
          end)
        rescue
          # Fire-and-forget must never fail the create — but it must not vanish either. This rescue used to
          # swallow every exception silently, which is precisely what made a broken fan-out undiagnosable.
          error ->
            Logger.error("conversation_created broadcast failed: #{Exception.message(error)}")
            :ok
        end
      end)
    end

    :ok
  end

  def broadcast_created(_response), do: :ok

  @doc """
  Broadcast `conversation_updated` to a conversation's participants — the live-inbox event behind FOUR
  triggers (`:message`, `:receipt`, `:title`, `:participant`).

  Delegates to `SharedInfra.ConversationBroadcast`, which owns the fan-out because the realtime channel
  (a different umbrella app, which cannot see ApiGatewayWeb) needs the SAME logic — one implementation, three
  callers, no chance of three different unread counts. This wrapper just supplies our endpoint. See there for
  the per-user row rationale and the `:only` / `:skip_if_unread` / `:removed_user_id` options.
  """
  def broadcast_updated(conversation_id, actor_user_id, trigger, opts \\ []) do
    SharedInfra.ConversationBroadcast.broadcast_updated(
      ApiGatewayWeb.Endpoint,
      conversation_id,
      actor_user_id,
      trigger,
      opts
    )
  end

  @doc "The reader's unread count BEFORE a mark_read — pass as `:skip_if_unread` so a no-op read is silent."
  defdelegate unread_before(conversation_id, user_id), to: SharedInfra.ConversationBroadcast

  @doc "Drop the internal `:created` flag before the response is rendered to the client (kept API-stable)."
  def strip_internal(response) when is_map(response),
    do: Map.drop(response, [:created, "created"])

  def strip_internal(response), do: response

  # The present_list inbox-row SHAPE, filled for a brand-new conversation (no last message yet). Not reusable
  # from present_list itself: that builds from a list-activity row (with last_message_* fields), whereas the
  # create response has none — so we match the shape with the documented new-conversation defaults.
  defp inbox_row(response) do
    %{
      conversation_id: cget(response, :conversation_id),
      type: cget(response, :type),
      title: cget(response, :title),
      last_message_preview: nil,
      last_message_kind: nil,
      unread_count: 0,
      updated_at: cget(response, :created_at)
    }
  end

  # The create response may cross the ConversationClient boundary atom-keyed (in-process) or string-keyed
  # (HTTP) — read either.
  # Presence-based (SharedInfra.Attrs): reads :created (a boolean) — `||` drops a stored false.
  defp cget(map, key) when is_map(map), do: SharedInfra.Attrs.get(map, key)
  defp cget(_map, _key), do: nil
end
