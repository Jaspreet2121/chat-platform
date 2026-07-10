defmodule RealtimeGateway.CallChannel do
  use Phoenix.Channel

  alias RealtimeGateway.Limits
  alias RealtimeGateway.TopicAuthorization

  @impl true
  def join("call:" <> call_id = topic, _payload, socket) do
    with :ok <- Limits.check_join(socket),
         :ok <- TopicAuthorization.authorize_join(topic, socket) do
      socket = assign(socket, :call_id, call_id)

      {:ok,
       %{
         topic: topic,
         call_id: call_id,
         user_id: socket.assigns.current_user_id,
         status: "joined"
       }, socket}
    end
  end

  # WebRTC signaling relay — fire-and-forget, high-frequency-capable → EPHEMERAL (dropped silently over limit).
  @impl true
  def handle_in("call_signal", payload, socket) do
    with :ok <- Limits.check_ephemeral(socket) do
      reply = %{
        event: "call_signal",
        call_id: socket.assigns.call_id,
        user_id: socket.assigns.current_user_id,
        payload: payload,
        status: "accepted"
      }

      {:reply, {:ok, reply}, socket}
    end
  end
end
