defmodule RealtimeGateway.UserChannel do
  use Phoenix.Channel

  alias RealtimeGateway.TopicAuthorization

  @impl true
  def join("user:" <> user_id = topic, _payload, socket) do
    with :ok <- TopicAuthorization.authorize_join(topic, socket) do
      socket = assign(socket, :topic_user_id, user_id)

      {:ok,
       %{
         topic: topic,
         user_id: user_id,
         current_user_id: socket.assigns.current_user_id,
         status: "joined"
       }, socket}
    end
  end
end
