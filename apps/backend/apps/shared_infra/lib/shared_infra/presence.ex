defmodule SharedInfra.Presence do
  @moduledoc """
  User-level ONLINE state + LAST-SEEN, the display side of presence. Deliberately SEPARATE from
  `SharedInfra.PresenceMarker` (the app/conversation push-suppression markers), because the two want opposite
  failure modes:

    * PresenceMarker is FAIL-OPEN — a Redis miss/error means "not viewing" so the notification service SENDS
      the push (a redundant push beats a missed one).
    * This module is FAIL-CLOSED — a Redis miss/error means OFFLINE. We must NEVER show a false "online": a
      stale green dot is a privacy tell (the user looks reachable when they aren't), so uncertainty resolves
      to offline.

  Keys (distinct from the push markers, so the two never entangle):
    * `presence:<user>:online`     — "1", short TTL (refreshed by the 30s connection heartbeat). Absent = offline.
    * `presence:<user>:last_seen`  — unix seconds of the last clean disconnect, long TTL.

  ONLINE = the socket is connected (join + heartbeat), independent of app foreground/background (which drive
  only push-suppression). last-seen lives in Redis rather than a users column: presence is ephemeral and
  high-write (every disconnect), and realtime_gateway (where the write fires on terminate) has no Repo.

  TRANSITION detection: `mark_online/1` uses an atomic `SET ... EX ttl GET`, so it refreshes the TTL every
  heartbeat AND tells the caller whether the key was ABSENT (an offline→online transition worth broadcasting)
  or already present (a heartbeat — stay silent). This is how we broadcast on change, not every 30s.

  Backed by an adapter (`:presence_adapter`, default the Redis one) so the transition/broadcast logic is
  testable without a live Redis.
  """

  @online_ttl_seconds 45
  # last-seen should survive well beyond a session; 30 days is plenty for "last seen 3 days ago".
  @last_seen_ttl_seconds 60 * 60 * 24 * 30
  def last_seen_ttl_seconds, do: @last_seen_ttl_seconds

  @type transition :: {:transition, :online} | :already_online | :error

  @callback mark_online(user_id :: String.t()) :: transition()
  @callback clear_online(user_id :: String.t(), now_unix :: integer()) :: :ok
  @callback online?(user_id :: String.t()) :: boolean()
  @callback last_seen(user_id :: String.t()) :: integer() | nil

  @doc "Mark the user online (refresh the TTL). Returns `{:transition, :online}` on the FIRST mark (broadcast!),
  `:already_online` on a heartbeat refresh (stay silent), `:error` on failure (fail-closed — do NOT broadcast)."
  def mark_online(user_id), do: adapter().mark_online(user_id)

  @doc "Mark the user offline and stamp last_seen = now. Best-effort → :ok."
  def clear_online(user_id, now_unix \\ nil), do: adapter().clear_online(user_id, now_unix || now_unix())

  @doc "Is the user online RIGHT NOW? FAIL-CLOSED: a miss OR any error → false (never a phantom green dot)."
  def online?(user_id), do: adapter().online?(user_id)

  @doc "Unix seconds of the user's last clean disconnect, or nil if unknown."
  def last_seen(user_id), do: adapter().last_seen(user_id)

  def online_ttl_seconds, do: @online_ttl_seconds

  defp now_unix, do: System.system_time(:second)

  def adapter,
    do: Application.get_env(:shared_infra, :presence_adapter, SharedInfra.Presence.RedisAdapter)

  # --- keys (single source of truth) ---
  def online_key(user_id), do: "presence:#{user_id}:online"
  def last_seen_key(user_id), do: "presence:#{user_id}:last_seen"

  defmodule RedisAdapter do
    @moduledoc "The production adapter — RedisKV-backed, fail-CLOSED on read."
    @behaviour SharedInfra.Presence

    alias SharedInfra.Presence
    alias SharedInfra.RedisKV

    @impl true
    def mark_online(user_id) when is_binary(user_id) and user_id != "" do
      case RedisKV.put_get(Presence.online_key(user_id), "1", Presence.online_ttl_seconds()) do
        {:ok, :was_absent} -> {:transition, :online}
        {:ok, {:was_present, _}} -> :already_online
        _ -> :error
      end
    rescue
      _ -> :error
    end

    def mark_online(_), do: :error

    @impl true
    def clear_online(user_id, now_unix) when is_binary(user_id) and user_id != "" do
      RedisKV.del(Presence.online_key(user_id))
      RedisKV.put(Presence.last_seen_key(user_id), Integer.to_string(now_unix), Presence.last_seen_ttl_seconds())
      :ok
    rescue
      _ -> :ok
    end

    def clear_online(_user_id, _now), do: :ok

    @impl true
    def online?(user_id) when is_binary(user_id) and user_id != "" do
      # FAIL-CLOSED: only a definite hit is "online"; a miss or ANY error is offline.
      case RedisKV.get(Presence.online_key(user_id)) do
        {:ok, _} -> true
        _ -> false
      end
    rescue
      _ -> false
    end

    def online?(_), do: false

    @impl true
    def last_seen(user_id) when is_binary(user_id) and user_id != "" do
      case RedisKV.get(Presence.last_seen_key(user_id)) do
        {:ok, value} ->
          case Integer.parse(value) do
            {ts, _} -> ts
            _ -> nil
          end

        _ ->
          nil
      end
    rescue
      _ -> nil
    end

    def last_seen(_), do: nil
  end
end
