defmodule RealtimeGateway.UserChannel do
  use Phoenix.Channel

  alias RealtimeGateway.Limits
  alias RealtimeGateway.TopicAuthorization

  # The user topic is the connection's lifecycle channel: every client joins user:<id> on app open, so it's
  # the reliable place to refresh the connection-counter entry (heartbeat) and release it on disconnect. Kept
  # well under RT_CONN_TTL_SECONDS (default 120s) so a live socket is never wrongly aged out of the count.
  @conn_heartbeat_ms 30_000

  @impl true
  def join("user:" <> user_id = topic, _payload, socket) do
    with :ok <- Limits.check_join(socket),
         :ok <- TopicAuthorization.authorize_join(topic, socket) do
      socket = assign(socket, :topic_user_id, user_id)
      # App-level presence: joining the user topic means the app is open → mark it foreground for the
      # notification service (skip web-push while the app is open ANYWHERE — in-app covers it). The
      # client refreshes/clears via app:foreground / app:background below; the TTL self-heals.
      mark_app(user_id)
      # Refresh this socket's connection-counter slot now and on a periodic heartbeat.
      Limits.touch_connection(socket)
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
    Process.send_after(self(), :conn_heartbeat, @conn_heartbeat_ms)
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
      user_id when is_binary(user_id) -> clear_app(user_id)
      _ -> :ok
    end

    # Immediate connection-counter decrement (the fast path); the counter's score-aging is the safety net
    # for a missed terminate (crash / node loss), so a dropped socket can never leak a slot permanently.
    Limits.release_connection(socket)

    :ok
  end

  # Redis I/O off the channel process so it never blocks realtime; fully fail-open.
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
