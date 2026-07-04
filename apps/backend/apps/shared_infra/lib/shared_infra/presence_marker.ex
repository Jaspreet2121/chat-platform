defmodule SharedInfra.PresenceMarker do
  @moduledoc """
  Cross-service "user is actively viewing this conversation" signal, bridged through Redis so the
  notification service (a separate node) can honor it — Phoenix.Presence is in-memory + local to the
  realtime gateway.

  The realtime gateway WRITES a short-TTL marker while a user has a conversation open (refreshed by a
  heartbeat, deleted on leave); `NotificationService.PushSender` READS it and skips the web-push for a
  recipient who's currently looking at that chat (the in-app path already updates them). This module is
  the single source of truth for the key format + TTL so writer and reader can never drift.

  Everything is BEST-EFFORT and FAIL-OPEN: a Redis hiccup on write means a redundant push; on read the
  caller must default to SENDING (never suppress on error). The TTL is the safety net — a crash that
  skips the delete self-heals in ≤ ttl seconds.
  """

  @ttl_seconds 45

  @doc "TTL (seconds) for a presence marker; the heartbeat must refresh well within this."
  def ttl_seconds, do: @ttl_seconds

  @doc ~S|Marker key for a (user, conversation): "presence:<user_id>:<conversation_id>".|
  def key(user_id, conversation_id), do: "presence:#{user_id}:#{conversation_id}"

  @doc "Mark the user present in the conversation (write/refresh the TTL). Best-effort → :ok always."
  def mark(user_id, conversation_id) do
    SharedInfra.RedisKV.put(key(user_id, conversation_id), "1", @ttl_seconds)
    :ok
  rescue
    _ -> :ok
  end

  @doc "Clear the marker (user left the conversation). Best-effort → :ok always."
  def clear(user_id, conversation_id) do
    SharedInfra.RedisKV.del(key(user_id, conversation_id))
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Whether the user is actively viewing the conversation right now. FAIL-OPEN: a miss OR any Redis
  error returns `false` (not present) so the caller SENDS — a redundant push beats a missed one.
  """
  def present?(user_id, conversation_id) do
    case SharedInfra.RedisKV.get(key(user_id, conversation_id)) do
      {:ok, _} -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
