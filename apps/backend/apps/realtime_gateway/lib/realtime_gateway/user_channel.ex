defmodule RealtimeGateway.UserChannel do
  use Phoenix.Channel

  alias RealtimeGateway.TopicAuthorization

  @impl true
  def join("user:" <> user_id = topic, _payload, socket) do
    with :ok <- TopicAuthorization.authorize_join(topic, socket) do
      socket = assign(socket, :topic_user_id, user_id)
      # App-level presence: joining the user topic means the app is open → mark it foreground for the
      # notification service (skip web-push while the app is open ANYWHERE — in-app covers it). The
      # client refreshes/clears via app:foreground / app:background below; the TTL self-heals.
      mark_app(user_id)

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
    mark_app(socket.assigns.topic_user_id)
    {:noreply, socket}
  end

  # Page hidden/closing → clear the marker so web-push resumes immediately (TTL is the fallback).
  @impl true
  def handle_in("app:background", _payload, socket) do
    clear_app(socket.assigns.topic_user_id)
    {:noreply, socket}
  end

  # Socket drop (tab closed / network loss) → clear best-effort; TTL covers a missed terminate.
  @impl true
  def terminate(_reason, socket) do
    case Map.get(socket.assigns, :topic_user_id) do
      user_id when is_binary(user_id) -> clear_app(user_id)
      _ -> :ok
    end

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
