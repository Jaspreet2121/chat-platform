defmodule ApiGatewayWeb.ConversationBroadcast do
  @moduledoc """
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
    # TEMPORARY DIAGNOSTIC LOGGING (BROADCAST_DEBUG) — remove once conversation_created is confirmed firing.
    Logger.info("BROADCAST_DEBUG entry: #{inspect(response)}")

    if cget(response, :created) == true do
      created_by = cget(response, :created_by)
      participants = cget(response, :participant_user_ids) || []
      row = inbox_row(response)

      Logger.info(
        "BROADCAST_DEBUG gate PASSED — participants=#{inspect(participants)} creator=#{inspect(created_by)} row=#{inspect(row)}"
      )

      Task.start(fn ->
        try do
          targets = Enum.reject(participants, &(is_nil(&1) or &1 == "" or &1 == created_by))
          # If this is [] the fan-out is a silent no-op — that alone would explain "nothing broadcasts".
          Logger.info("BROADCAST_DEBUG targets after excluding creator: #{inspect(targets)}")

          Enum.each(targets, fn user_id ->
            Logger.info("BROADCAST_DEBUG → user:#{user_id}")
            result = ApiGatewayWeb.Endpoint.broadcast("user:" <> user_id, "conversation_created", row)
            Logger.info("BROADCAST_DEBUG broadcast result for user:#{user_id}: #{inspect(result)}")
          end)
        rescue
          # This rescue previously swallowed EVERYTHING silently — the most likely blind spot.
          error ->
            Logger.info("BROADCAST_DEBUG RESCUED inside task: #{inspect(error)}")
            :ok
        end
      end)
    else
      Logger.info("BROADCAST_DEBUG SKIPPED: created=#{inspect(cget(response, :created))}")
    end

    :ok
  end

  def broadcast_created(other) do
    Logger.info("BROADCAST_DEBUG entry — response is NOT A MAP: #{inspect(other)}")
    :ok
  end

  @doc "Drop the internal `:created` flag before the response is rendered to the client (kept API-stable)."
  def strip_internal(response) when is_map(response), do: Map.drop(response, [:created, "created"])
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
  defp cget(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp cget(_map, _key), do: nil
end
