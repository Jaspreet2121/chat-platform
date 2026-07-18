defmodule RealtimeGateway.UserPresence do
  @moduledoc """
  Channel-side presence coordinator: turns the user socket's lifecycle (join / heartbeat / terminate) into
  authorized `presence_updated` broadcasts, and manages a socket's presence SUBSCRIPTIONS.

  MODEL — subscribe-based, authorize-at-subscribe:
    * A viewer S declares whose presence it wants (`presence:subscribe`). Each target U is authorized ONCE
      here (`SharedInfra.PresenceAuthz.can_see?/2` — a shared conversation AND U's visibility permits). If
      allowed, S's channel process subscribes to the `presence:<U>` PubSub topic and gets an immediate
      snapshot. Unauthorized targets are dropped SILENTLY (no reveal that U even exists).
    * A transition for U (online / offline) broadcasts ONCE to `presence:<U>`; every subscribed viewer gets
      it. No per-transition contact query — that cost was paid at subscribe.
    * The broadcast is additionally gated on U's visibility != "nobody" AT BROADCAST TIME, so a viewer who
      subscribed while U was visible stops receiving the instant U flips to "nobody".

  Cross-node: the `presence:<U>` topics live on the socket endpoint's clustered PubSub (the same one
  message/conversation fan-out uses), so a viewer on any node receives U's transition from any other node.

  Redis I/O runs OFF the channel process (Task.start) so presence never blocks realtime; the online store
  (`SharedInfra.Presence`) is fail-CLOSED on read (never a phantom "online").

  PRESENCE_DEBUG logging is intentionally IN (removed in a follow-up once verified in prod), tagged per
  mechanism so a silent failure names which path broke.
  """

  require Logger

  import Phoenix.Socket, only: [assign: 3]

  alias SharedInfra.Presence, as: Store
  alias SharedInfra.PresenceAuthz

  @doc "Mark this socket's user online; on a genuine offline→online transition, broadcast online:true."
  def mark_online_and_broadcast(socket) do
    user_id = current_user(socket)
    endpoint = socket.endpoint

    if is_binary(user_id) do
      Task.start(fn ->
        case Store.mark_online(user_id) do
          {:transition, :online} ->
            Logger.info("PRESENCE_DEBUG kind=online user=#{user_id} (transition) → broadcasting")
            broadcast_presence(endpoint, user_id, true, nil)

          :already_online ->
            :ok

          :error ->
            # Fail-closed: a store error does NOT broadcast a maybe-online. The next heartbeat retries.
            Logger.error("PRESENCE_DEBUG kind=online user=#{user_id} store error (no broadcast)")
            :ok
        end
      end)
    end

    :ok
  end

  @doc "Mark this socket's user offline (+ stamp last_seen) and broadcast online:false to subscribers."
  def clear_online_and_broadcast(socket) do
    user_id = current_user(socket)
    endpoint = socket.endpoint

    if is_binary(user_id) do
      now = System.system_time(:second)

      Task.start(fn ->
        Store.clear_online(user_id, now)
        Logger.info("PRESENCE_DEBUG kind=offline user=#{user_id} → broadcasting last_seen=#{now}")
        broadcast_presence(endpoint, user_id, false, now)
      end)
    end

    :ok
  end

  @doc "Authorize + subscribe this socket to each requested target; push an initial snapshot for each."
  def subscribe(socket, user_ids) do
    me = current_user(socket)
    requested = user_ids |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.uniq()

    {socket, authorized} =
      Enum.reduce(requested, {socket, []}, fn target, {sock, acc} ->
        cond do
          MapSet.member?(sock.assigns.presence_subs, target) ->
            {sock, [target | acc]}

          PresenceAuthz.can_see?(me, target) ->
            # endpoint.subscribe runs in the CHANNEL process (this is called from handle_in), so the channel
            # receives the presence:<target> broadcasts and forwards them (user_channel handle_info).
            sock.endpoint.subscribe(topic(target))
            sock = assign(sock, :presence_subs, MapSet.put(sock.assigns.presence_subs, target))
            snapshot(target)
            {sock, [target | acc]}

          true ->
            # Not a contact / not permitted → dropped silently.
            {sock, acc}
        end
      end)

    Logger.info(
      "PRESENCE_DEBUG kind=subscribe user=#{me} requested=#{inspect(requested)} authorized=#{inspect(Enum.reverse(authorized))}"
    )

    {socket, Enum.reverse(authorized)}
  end

  @doc "Unsubscribe this socket from each target's presence."
  def unsubscribe(socket, user_ids) do
    Enum.reduce(user_ids, socket, fn target, sock ->
      if is_binary(target) and MapSet.member?(sock.assigns.presence_subs, target) do
        sock.endpoint.unsubscribe(topic(target))
        assign(sock, :presence_subs, MapSet.delete(sock.assigns.presence_subs, target))
      else
        sock
      end
    end)
  end

  @doc """
  Re-authorize a presence delivery and forward it to the client ONLY if the viewer may still see the target.

  This is the "authorize every delivery" gate: a subscription is authorized once at subscribe time, but the
  viewer may have since lost the shared conversation, or the target may have flipped to "nobody" — either of
  which `PresenceAuthz.can_see?/2` catches. Runs OFF the channel process (the authz does client calls); on
  pass it sends `{:presence_forward, …}` back to the channel to push, on fail it drops silently. So the live
  path can never leak to an ex-contact — matching the read path (`PresenceRead`), which re-checks every call.
  """
  def forward_if_authorized(socket, event, payload) do
    me = current_user(socket)
    target = Map.get(payload, "user_id") || Map.get(payload, :user_id)
    channel_pid = self()

    Task.start(fn ->
      if is_binary(me) and is_binary(target) and PresenceAuthz.can_see?(me, target) do
        send(channel_pid, {:presence_forward, event, payload})
      end
    end)

    :ok
  end

  @doc "The presence PubSub topic for a user (exposed for tests)."
  def topic(user_id), do: "presence:" <> user_id

  # --- internals ---

  # Broadcast a transition on the target's topic, GATED on visibility != nobody (one check gating the whole
  # broadcast — subscribers already passed the shared-conversation check at subscribe time).
  defp broadcast_presence(endpoint, user_id, online, last_seen) do
    if visible?(user_id) do
      endpoint.broadcast(topic(user_id), "presence_updated", %{
        "user_id" => user_id,
        "online" => online,
        "last_seen_at" => iso8601(last_seen)
      })
    else
      Logger.info(
        "PRESENCE_DEBUG kind=#{kind(online)} user=#{user_id} suppressed (visibility=nobody)"
      )

      :ok
    end
  end

  # Read the target's current state OFF the channel process, then hand the snapshot back to the channel
  # process (self()) to push — so a slow Redis never blocks the channel on subscribe.
  defp snapshot(target) do
    channel_pid = self()

    Task.start(fn ->
      online = Store.online?(target)
      last_seen = if online, do: nil, else: Store.last_seen(target)

      send(
        channel_pid,
        {:presence_snapshot,
         %{"user_id" => target, "online" => online, "last_seen_at" => iso8601(last_seen)}}
      )
    end)

    :ok
  end

  defp visible?(user_id) do
    case SharedInfra.UserClient.last_seen_visibility(%{"user_id" => user_id}) do
      {:ok, result} ->
        case Map.get(result, :last_seen_visibility) || Map.get(result, "last_seen_visibility") do
          # FAIL-CLOSED: only a confirmed non-"nobody" string is visible. A nil / missing / unknown value
          # (a degraded response, a schema skew) must NOT broadcast — `nil != "nobody"` would leak.
          "nobody" -> false
          v when is_binary(v) and v != "" -> true
          _ -> false
        end

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp current_user(socket),
    do: Map.get(socket.assigns, :current_user_id) || Map.get(socket.assigns, :topic_user_id)

  defp iso8601(nil), do: nil
  defp iso8601(unix) when is_integer(unix), do: unix |> DateTime.from_unix!() |> DateTime.to_iso8601()

  defp kind(true), do: "online"
  defp kind(false), do: "offline"
end
