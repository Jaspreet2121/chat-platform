defmodule RealtimeGateway.ConversationChannel do
  use Phoenix.Channel

  alias RealtimeGateway.Presence
  alias RealtimeGateway.TopicAuthorization

  @impl true
  def join("conversation:" <> conversation_id = topic, _payload, socket) do
    with :ok <- TopicAuthorization.authorize_join(topic, socket) do
      socket = assign(socket, :conversation_id, conversation_id)
      send(self(), :after_join)

      {:ok,
       %{
         topic: topic,
         conversation_id: conversation_id,
         user_id: Map.get(socket.assigns, :current_user_id),
         status: "joined"
       }, socket}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    with {:ok, user_id} <- current_user_id(socket),
         {:ok, _ref} <-
           Presence.track(socket, user_id, %{
             user_id: user_id,
             online_at: now_iso8601()
           }) do
      push(socket, "presence_state", Presence.list(socket))
    end

    {:noreply, socket}
  end

  @impl true
  def handle_in("typing_started", payload, socket) do
    reply = conversation_reply("typing_started", payload, socket)
    broadcast_from(socket, "presence_updated", Map.put(reply, :typing, true))

    {:reply, {:ok, reply}, socket}
  end

  def handle_in("typing:start", _payload, socket) do
    typing_event("typing_started", socket)
  end

  def handle_in("typing:stop", _payload, socket) do
    typing_event("typing_stopped", socket)
  end

  def handle_in("typing_stopped", payload, socket) do
    reply = conversation_reply("typing_stopped", payload, socket)
    broadcast_from(socket, "presence_updated", Map.put(reply, :typing, false))

    {:reply, {:ok, reply}, socket}
  end

  def handle_in("message_read", payload, socket) do
    reply = conversation_reply("message_read", payload, socket)
    broadcast_from(socket, "receipt_updated", Map.put(reply, :receipt_type, "read"))

    {:reply, {:ok, reply}, socket}
  end

  def handle_in("message_delivered", payload, socket) do
    reply = conversation_reply("message_delivered", payload, socket)
    broadcast_from(socket, "receipt_updated", Map.put(reply, :receipt_type, "delivered"))

    {:reply, {:ok, reply}, socket}
  end

  def handle_in("message:create", payload, socket) do
    create_message(payload, socket)
  end

  def handle_in("message:new", payload, socket) do
    create_message(payload, socket)
  end

  def handle_in("message:update", payload, socket) do
    update_message(payload, socket)
  end

  def handle_in("message:delete", payload, socket) do
    delete_message(payload, socket)
  end

  defp create_message(payload, socket) do
    with :ok <- validate_message_payload(payload),
         {:ok, sender_user_id} <- current_user_id(socket),
         {:ok, response} <-
           payload
           |> Map.put("conversation_id", socket.assigns.conversation_id)
           |> Map.put("sender_user_id", sender_user_id)
           |> SharedInfra.MessageClient.create_message() do
      broadcast_from(socket, "message_created", response)
      {:reply, {:ok, response}, socket}
    else
      {:error, :missing_user} ->
        {:reply,
         {:error,
          %{code: "realtime.unauthorized", message: "Missing or invalid socket authentication"}},
         socket}

      {:error, :message_unavailable} ->
        unavailable_reply(socket)

      _ ->
        {:reply,
         {:error, %{code: "realtime.invalid_event", message: "Message event payload is invalid"}},
         socket}
    end
  end

  defp update_message(payload, socket) do
    with :ok <- validate_update_payload(payload),
         {:ok, actor_user_id} <- current_user_id(socket),
         {:ok, response} <-
           payload
           |> Map.put("conversation_id", socket.assigns.conversation_id)
           |> Map.put("actor_user_id", actor_user_id)
           |> SharedInfra.MessageClient.update_message() do
      broadcast_from(socket, "message_updated", response)
      {:reply, {:ok, response}, socket}
    else
      {:error, :missing_user} -> unauthorized_reply(socket)
      {:error, :message_forbidden} -> forbidden_reply(socket)
      {:error, :message_unavailable} -> unavailable_reply(socket)
      _ -> invalid_event_reply(socket)
    end
  end

  defp delete_message(payload, socket) do
    with :ok <- validate_delete_payload(payload),
         {:ok, actor_user_id} <- current_user_id(socket),
         {:ok, response} <-
           payload
           |> Map.put("conversation_id", socket.assigns.conversation_id)
           |> Map.put("actor_user_id", actor_user_id)
           |> SharedInfra.MessageClient.delete_message() do
      broadcast_from(socket, "message_deleted", response)
      {:reply, {:ok, response}, socket}
    else
      {:error, :missing_user} -> unauthorized_reply(socket)
      {:error, :message_forbidden} -> forbidden_reply(socket)
      {:error, :message_unavailable} -> unavailable_reply(socket)
      _ -> invalid_event_reply(socket)
    end
  end

  defp unauthorized_reply(socket) do
    {:reply,
     {:error,
      %{code: "realtime.unauthorized", message: "Missing or invalid socket authentication"}},
     socket}
  end

  defp forbidden_reply(socket) do
    {:reply,
     {:error, %{code: "realtime.forbidden", message: "You can only modify your own messages"}},
     socket}
  end

  defp invalid_event_reply(socket) do
    {:reply,
     {:error, %{code: "realtime.invalid_event", message: "Message event payload is invalid"}},
     socket}
  end

  # message-service unreachable over the network (HTTP adapter): reject with a distinct signal.
  defp unavailable_reply(socket) do
    {:reply, {:error, %{code: "realtime.unavailable", message: "Message service is unavailable"}},
     socket}
  end

  defp typing_event(event, socket) do
    with {:ok, user_id} <- current_user_id(socket) do
      payload = %{
        conversation_id: socket.assigns.conversation_id,
        user_id: user_id,
        occurred_at: now_iso8601()
      }

      broadcast_from(socket, event, payload)
      {:reply, {:ok, Map.put(payload, :event, event)}, socket}
    else
      {:error, :missing_user} ->
        {:reply,
         {:error,
          %{code: "realtime.unauthorized", message: "Missing or invalid socket authentication"}},
         socket}
    end
  end

  defp conversation_reply(event, payload, socket) do
    %{
      event: event,
      conversation_id: socket.assigns.conversation_id,
      user_id: Map.get(socket.assigns, :current_user_id),
      payload: payload,
      status: "accepted"
    }
  end

  defp validate_message_payload(%{"message_type" => "text", "body" => body})
       when is_binary(body) and body != "" do
    :ok
  end

  defp validate_message_payload(%{"message_type" => "text"}), do: {:error, :invalid_event}

  defp validate_message_payload(%{"message_type" => "media", "media_id" => media_id})
       when is_binary(media_id) and media_id != "" do
    :ok
  end

  defp validate_message_payload(%{"message_type" => "media"}), do: {:error, :invalid_event}

  defp validate_message_payload(%{"message_type" => message_type})
       when is_binary(message_type) and message_type != "" do
    :ok
  end

  defp validate_message_payload(_payload), do: {:error, :invalid_event}

  defp validate_update_payload(%{"message_id" => message_id, "body" => body})
       when is_binary(message_id) and message_id != "" and is_binary(body) and body != "" do
    :ok
  end

  defp validate_update_payload(_payload), do: {:error, :invalid_event}

  defp validate_delete_payload(%{"message_id" => message_id})
       when is_binary(message_id) and message_id != "" do
    :ok
  end

  defp validate_delete_payload(_payload), do: {:error, :invalid_event}

  defp current_user_id(socket) do
    user_id = Map.get(socket.assigns, :user_id) || Map.get(socket.assigns, :current_user_id)

    case user_id do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_user}
    end
  end

  defp now_iso8601 do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
