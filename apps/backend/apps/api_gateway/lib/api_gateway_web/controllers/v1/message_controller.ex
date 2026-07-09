defmodule ApiGatewayWeb.V1.MessageController do
  @moduledoc """
  Public `/v1` message send + list. Every request is gated by `ConversationAuthz.authorize_conversation/2`:
  an app (secret-key) actor needs only tenant scope; an end-user (JWT) actor must additionally be an active
  participant of the conversation. Any failure — cross-tenant id, unknown id, or a non-member — returns a
  404 with a generic body (never reveal existence, never 403). Send accepts an Idempotency-Key header so a
  retried POST returns the SAME message instead of duplicating.
  """

  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse
  alias ApiGatewayWeb.V1.ConversationAuthz

  def create(conn, %{"id" => conversation_id} = params) do
    app_id = conn.assigns.v1_app_id

    with {:ok, _conversation} <- ConversationAuthz.authorize_conversation(conn, conversation_id),
         {:ok, sender_user_id} <- resolve_sender(conn, app_id, params),
         {:ok, message} <- send_message(conn, app_id, conversation_id, sender_user_id, params) do
      conn
      |> put_status(:created)
      |> json(message)
    else
      {:error, :not_found} ->
        not_found(conn)

      {:error, :conversation_unavailable} ->
        ErrorResponse.service_unavailable(conn, "v1.unavailable")

      {:error, :message_unavailable} ->
        ErrorResponse.service_unavailable(conn, "v1.unavailable")

      _ ->
        ErrorResponse.invalid_request(conn, "v1.invalid_request")
    end
  end

  # Optional compound-keyset cursor pagination (additive — no cursor params → the unchanged recent page):
  #   forward backfill : after_created_at + after_id  (strictly-after, oldest→newest)
  #   history scroll   : before_created_at + before_id (strictly-before, newest→older)
  #   limit            : default 30, capped at 100
  # next_cursor in the response is the keyset {created_at, message_id} of the page's last row (or null at
  # the end). The membership gate (authorize_conversation) is unchanged by the cursor logic.
  def index(conn, %{"id" => conversation_id} = params) do
    with {:ok, _conversation} <- ConversationAuthz.authorize_conversation(conn, conversation_id),
         {:ok, result} <-
           SharedInfra.MessageClient.list_messages(list_attrs(conversation_id, params)) do
      json(conn, result)
    else
      {:error, :not_found} -> not_found(conn)
      _ -> ErrorResponse.invalid_request(conn, "v1.invalid_request")
    end
  end

  # Thread only the recognised cursor params through (unknown params ignored). Blank/absent cursor keys
  # are dropped so the store sees "no cursor" and serves the recent page exactly as before.
  defp list_attrs(conversation_id, params) do
    %{"conversation_id" => conversation_id, "limit" => list_limit(params)}
    |> put_present("after_created_at", params["after_created_at"])
    |> put_present("after_id", params["after_id"])
    |> put_present("before_created_at", params["before_created_at"])
    |> put_present("before_id", params["before_id"])
  end

  defp put_present(attrs, key, value) when is_binary(value) and value != "",
    do: Map.put(attrs, key, value)

  defp put_present(attrs, _key, _value), do: attrs

  defp list_limit(params) do
    case Integer.parse(to_string(params["limit"] || "")) do
      {n, _} -> n |> max(1) |> min(100)
      :error -> 30
    end
  end

  # An end-user JWT sends AS that user; a server (secret key) names the sender via a "sender" external id.
  defp resolve_sender(conn, app_id, params) do
    cond do
      is_binary(conn.assigns[:v1_user_id]) ->
        {:ok, conn.assigns.v1_user_id}

      is_binary(Map.get(params, "sender")) and Map.get(params, "sender") != "" ->
        case SharedInfra.AuthClient.resolve_external_user(%{
               "app_id" => app_id,
               "external_id" => Map.get(params, "sender")
             }) do
          {:ok, %{user_id: user_id}} -> {:ok, user_id}
          _ -> {:error, :invalid_request}
        end

      true ->
        {:error, :invalid_request}
    end
  end

  # The broadcast (fan_out) lives INSIDE the two insert branches (no-key, and key + :miss) and NEVER in
  # the cached-replay branch — so a client retry with the same Idempotency-Key returns the same message
  # but does NOT re-deliver a duplicate live event to every connected client.
  defp send_message(conn, app_id, conversation_id, sender_user_id, params) do
    case idempotency_key(conn) do
      nil ->
        with {:ok, message} <- do_send(conversation_id, sender_user_id, params) do
          fan_out(conversation_id, sender_user_id, message)
          {:ok, message}
        end

      key ->
        case ApiGatewayWeb.V1Runtime.idem_get(app_id, conversation_id, key) do
          {:ok, message} ->
            # Idempotent REPLAY — the message was already inserted + fanned out on the first request.
            {:ok, message}

          :miss ->
            with {:ok, message} <- do_send(conversation_id, sender_user_id, params) do
              ApiGatewayWeb.V1Runtime.idem_put(app_id, conversation_id, key, message)
              fan_out(conversation_id, sender_user_id, message)
              {:ok, message}
            end
        end
    end
  end

  # Broadcast a freshly-INSERTED message to connected sockets, mirroring the socket send path
  # (conversation_channel.create_message) so a client can't tell which path produced it — same endpoint,
  # same PubSub, same "message_created" event, same `message` payload the socket path broadcasts.
  #
  # Fire-and-forget (Task.start + rescue), exactly like the socket path's notify_user_topics: a broadcast
  # or participant-lookup hiccup must never turn a successful 201 into an error.
  #
  # NOTE on the conversation-topic broadcast: the socket path uses broadcast_from to exclude the sender's
  # SOCKET; a controller has no socket to exclude, so the sender's OTHER conversation-topic subscribers
  # (e.g. another tab) WILL receive it. That is intentional + safe — the SDK reconciles by real
  # message_id, and a sender's other tabs SHOULD see it. The user:<id> mirror still EXCLUDES the sender.
  defp fan_out(conversation_id, sender_user_id, message) do
    Task.start(fn ->
      try do
        ApiGatewayWeb.Endpoint.broadcast("conversation:" <> conversation_id, "message_created", message)
        notify_user_topics(conversation_id, sender_user_id, message)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  # Mirror message_created onto each OTHER participant's user:<id> topic — reuse the socket path's logic
  # verbatim (participants via get_conversation, reject nil + the SENDER). Same as
  # conversation_channel.notify_user_topics.
  defp notify_user_topics(conversation_id, sender_user_id, message) do
    case SharedInfra.ConversationClient.get_conversation(%{
           "conversation_id" => conversation_id,
           "user_id" => sender_user_id
         }) do
      {:ok, conversation} ->
        (Map.get(conversation, :participants) || Map.get(conversation, "participants") || [])
        |> Enum.map(fn p -> Map.get(p, :user_id) || Map.get(p, "user_id") end)
        |> Enum.reject(&(&1 in [nil, sender_user_id]))
        |> Enum.each(fn user_id ->
          ApiGatewayWeb.Endpoint.broadcast("user:" <> user_id, "message_created", message)
        end)

      _ ->
        :ok
    end
  end

  defp do_send(conversation_id, sender_user_id, params) do
    SharedInfra.MessageClient.create_message(%{
      "conversation_id" => conversation_id,
      "sender_user_id" => sender_user_id,
      "message_type" => Map.get(params, "message_type", "text"),
      "body" => Map.get(params, "body"),
      "metadata" => Map.get(params, "metadata")
    })
  end

  defp idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [key | _] when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end

  defp not_found(conn), do: ErrorResponse.not_found(conn, "v1.not_found", "Not found")
end
