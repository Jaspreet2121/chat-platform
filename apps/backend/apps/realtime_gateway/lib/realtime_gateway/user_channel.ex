defmodule RealtimeGateway.UserChannel do
  use Phoenix.Channel

  alias RealtimeGateway.Limits
  alias RealtimeGateway.UserPresence, as: ChannelPresence
  alias RealtimeGateway.TopicAuthorization

  # The user topic is the connection's lifecycle channel: every client joins user:<id> on app open, so it's
  # the reliable place to refresh the connection-counter entry (heartbeat) and release it on disconnect. Kept
  # well under RT_CONN_TTL_SECONDS (default 120s) so a live socket is never wrongly aged out of the count.
  @conn_heartbeat_ms 30_000
  # REVOCATION FALLBACK: re-verify the (user, device) session every Nth heartbeat (10 × 30s ≈ 5 min).
  # The primary path is the gateway's disconnect broadcast at revoke time; this catches a MISSED signal
  # (restart mid-call, a revocation written outside the gateway) and admin suspend/ban (which touches no
  # device_sessions row). COST SCALING: one indexed EXISTS per live socket per 5 minutes — N concurrent
  # sockets ⇒ N/300 queries/sec (10k sockets ≈ 33/s); if that number ever matters, this constant is the
  # dial (raise the interval before caching anything).
  @session_recheck_beats 10

  @impl true
  def join("user:" <> user_id = topic, _payload, socket) do
    with :ok <- Limits.check_join(socket),
         :ok <- TopicAuthorization.authorize_join(topic, socket) do
      socket = assign(socket, :topic_user_id, user_id)
      socket = assign(socket, :presence_subs, %{})

      # App-level presence: joining the user topic means the app is open → mark it foreground for the
      # notification service (skip web-push while the app is open ANYWHERE — in-app covers it). The
      # client refreshes/clears via app:foreground / app:background below; the TTL self-heals.
      mark_app(user_id)
      # Refresh this socket's connection-counter slot now and on a periodic heartbeat.
      Limits.touch_connection(socket)

      # DISPLAY presence: mark this user ONLINE and, if this is a fresh online (not a heartbeat/reconnect),
      # broadcast it to authorized subscribers. Distinct from the app marker above (push-suppression).
      ChannelPresence.mark_online_and_broadcast(socket)
      Process.send_after(self(), :conn_heartbeat, @conn_heartbeat_ms)

      {:ok,
       %{
         topic: topic,
         user_id: user_id,
         current_user_id: socket.assigns.current_user_id,
         status: "joined"
       }, socket}
    end
  end

  # A client tells the gateway WHOSE presence it wants (the people in its inbox / open chat). Each target is
  # authorized (shared conversation AND the target's visibility permits) BEFORE the socket is subscribed —
  # unauthorized targets are silently dropped (never an existence/visibility reveal). The authorized set is
  # returned, and an initial snapshot for each is pushed immediately so the client doesn't wait for the next
  # transition.
  @impl true
  def handle_in("presence:subscribe", %{"user_ids" => user_ids}, socket) when is_list(user_ids) do
    case Limits.check_ephemeral(socket) do
      :ok ->
        {socket, authorized} = ChannelPresence.subscribe(socket, user_ids)
        {:reply, {:ok, %{subscribed: authorized}}, socket}

      dropped ->
        dropped
    end
  end

  def handle_in("presence:subscribe", _payload, socket),
    do: {:reply, {:error, %{reason: "invalid_request"}}, socket}

  @impl true
  def handle_in("presence:unsubscribe", %{"user_ids" => user_ids}, socket)
      when is_list(user_ids) do
    case Limits.check_ephemeral(socket) do
      :ok -> {:reply, {:ok, %{}}, ChannelPresence.unsubscribe(socket, user_ids)}
      dropped -> dropped
    end
  end

  def handle_in("presence:unsubscribe", _payload, socket),
    do: {:reply, {:error, %{reason: "invalid_request"}}, socket}

  # Client heartbeat while the page is visible → refresh the app-foreground marker within its TTL.
  @impl true
  def handle_in("app:foreground", _payload, socket) do
    case Limits.check_ephemeral(socket) do
      :ok ->
        mark_app(socket.assigns.topic_user_id)
        {:noreply, socket}

      dropped ->
        dropped
    end
  end

  # Page hidden/closing → clear the marker so web-push resumes immediately (TTL is the fallback).
  @impl true
  def handle_in("app:background", _payload, socket) do
    case Limits.check_ephemeral(socket) do
      :ok ->
        clear_app(socket.assigns.topic_user_id)
        {:noreply, socket}

      dropped ->
        dropped
    end
  end

  # Call RING signaling (Phase-1 LiveKit). The caller pushes `call:*` on their OWN user:<id>; the handler
  # persists via CallStore and broadcasts to the other party's user:<id>. Auth (self / caller-callee) is
  # enforced in CallSignaling against the persisted call row. LiveKit carries the media — this is control
  # only (invite/accept/reject/cancel/hangup); no SDP/ICE here.
  @impl true
  def handle_in("call:" <> _ = event, payload, socket) do
    with :ok <- Limits.check_write(socket) do
      RealtimeGateway.CallSignaling.handle_event(event, payload, socket)
    end
  end

  # Periodic connection-counter heartbeat — keeps this socket's slot fresh so it isn't aged out mid-session.
  @impl true
  def handle_info(:conn_heartbeat, socket) do
    Limits.touch_connection(socket)

    # Refresh the online marker's TTL so it never lapses mid-session. mark_online is a no-op broadcast when
    # already online (the common case) — it re-broadcasts ONLY if the key had expired (a genuine transition).
    ChannelPresence.mark_online_and_broadcast(socket)

    beats = (socket.assigns[:conn_beats] || 0) + 1
    socket = assign(socket, :conn_beats, beats)

    if rem(beats, @session_recheck_beats) == 0 and not session_still_active?(socket) do
      # Terminate the WHOLE socket (every channel), exactly as the revoke-time broadcast would have —
      # the reconnect then fails auth at connect (current_session rejects revoked/suspended).
      socket.endpoint.broadcast(socket.id, "disconnect", %{})
    end

    Process.send_after(self(), :conn_heartbeat, @conn_heartbeat_ms)
    {:noreply, socket}
  end

  # A presence transition for a user this socket SUBSCRIBED to. RE-AUTHORIZE the delivery (off-process) before
  # forwarding: a subscription is authorized at subscribe time, but the viewer may have SINCE lost the shared
  # conversation or the target may have tightened visibility — "authorize every delivery" so a stale
  # subscription can't keep leaking. The push happens via {:presence_forward, …} once authorized.
  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "presence:" <> _, event: event, payload: payload},
        socket
      ) do
    ChannelPresence.forward_if_authorized(socket, event, payload)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:presence_forward, event, payload}, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  # The initial snapshot for a freshly-subscribed target (read off-process, handed back here to push).
  @impl true
  def handle_info({:presence_snapshot, payload}, socket) do
    push(socket, "presence_updated", payload)
    {:noreply, socket}
  end

  # Server-side ring timeout (scheduled by CallSignaling.invite in the caller's channel process).
  @impl true
  def handle_info({:call_ring_timeout, call_id}, socket) do
    RealtimeGateway.CallSignaling.ring_timeout(call_id, socket)
    {:noreply, socket}
  end

  # Group ring timeout (scheduled by CallSignaling.group_invite in the initiator's channel process).
  @impl true
  def handle_info({:group_ring_timeout, call_id}, socket) do
    RealtimeGateway.CallSignaling.group_ring_timeout(call_id, socket)
    {:noreply, socket}
  end

  # Socket drop (tab closed / network loss) → clear best-effort; TTL covers a missed terminate.
  @impl true
  def terminate(_reason, socket) do
    case Map.get(socket.assigns, :topic_user_id) do
      user_id when is_binary(user_id) ->
        clear_app(user_id)

        # DISPLAY presence: mark offline (+ stamp last_seen) and broadcast to authorized subscribers.
        ChannelPresence.clear_online_and_broadcast(socket)

      _ ->
        :ok
    end

    # Immediate connection-counter decrement (the fast path); the counter's score-aging is the safety net
    # for a missed terminate (crash / node loss), so a dropped socket can never leak a slot permanently.
    Limits.release_connection(socket)

    :ok
  end

  # Redis I/O off the channel process so it never blocks realtime; fully fail-open.
  # The fallback's oracle. Only REAL device sessions are checked: /v1 end-user sockets ("end_user") and
  # the dev placeholder aren't device_sessions rows, and with socket auth disabled (Docker-free dev)
  # there is nothing to verify. FAIL-OPEN on auth unavailability — an auth blip must not sever every
  # socket in the fleet; the next re-check retries.
  defp session_still_active?(socket) do
    device_id = socket.assigns[:device_id]

    if socket_auth_enabled?() and is_binary(device_id) and
         device_id not in ["end_user", "device_placeholder"] do
      case SharedInfra.AuthClient.session_active?(%{
             "user_id" => socket.assigns.current_user_id,
             "device_id" => device_id
           }) do
        {:ok, %{active: false}} -> false
        {:ok, %{"active" => false}} -> false
        _ -> true
      end
    else
      true
    end
  rescue
    _ -> true
  end

  defp socket_auth_enabled? do
    Application.get_env(:realtime_gateway, :socket_auth_persistence, false) ||
      System.get_env("REALTIME_AUTH_DB_BACKED") in ["true", "1", "yes"]
  end

  defp mark_app(user_id) when is_binary(user_id) do
    Task.start(fn -> SharedInfra.PresenceMarker.mark_app(user_id) end)
    :ok
  end

  defp mark_app(_), do: :ok

  defp clear_app(user_id) when is_binary(user_id) do
    Task.start(fn -> SharedInfra.PresenceMarker.clear_app(user_id) end)
    :ok
  end

  defp clear_app(_), do: :ok
end
