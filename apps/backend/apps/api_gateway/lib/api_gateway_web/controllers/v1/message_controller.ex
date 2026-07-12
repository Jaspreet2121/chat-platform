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
         :ok <- validate_media(conn, app_id, params),
         {:ok, message} <- send_message(conn, app_id, conversation_id, sender_user_id, params) do
      conn
      |> put_status(:created)
      |> json(message)
    else
      {:error, :not_found} ->
        not_found(conn)

      # The caller attached a media_id they can't own / isn't a ready `message` asset in their app. This is
      # asserting ownership of an id, not an existence-reveal concern (same reasoning as a1ce358's
      # avatar_media_id) → 422, and no message is created.
      {:error, :invalid_media} ->
        ErrorResponse.unprocessable_entity(conn, "v1.invalid_media", "Invalid media attachment")

      {:error, :conversation_unavailable} ->
        ErrorResponse.service_unavailable(conn, "v1.unavailable")

      {:error, :message_unavailable} ->
        ErrorResponse.service_unavailable(conn, "v1.unavailable")

      _ ->
        ErrorResponse.invalid_request(conn, "v1.invalid_request")
    end
  end

  # A media attachment must be a READY `message` asset in the caller's app; an end-user actor must also OWN
  # it (an app actor is tenant-scoped). No media_id → an ordinary text message (unchanged). Failure → 422.
  defp validate_media(conn, app_id, params) do
    case media_id_param(params) do
      nil ->
        :ok

      media_id ->
        case SharedInfra.MediaClient.get_asset(%{"media_id" => media_id, "app_id" => app_id}) do
          {:ok, asset} ->
            owner_ok =
              case conn.assigns[:v1_user_id] do
                uid when is_binary(uid) and uid != "" -> aget(asset, :owner_user_id) == uid
                _ -> true
              end

            if aget(asset, :purpose) == "message" and aget(asset, :status) == "ready" and owner_ok,
              do: :ok,
              else: {:error, :invalid_media}

          _ ->
            {:error, :invalid_media}
        end
    end
  end

  defp media_id_param(params) do
    case Map.get(params, "media_id") do
      media_id when is_binary(media_id) and media_id != "" -> media_id
      _ -> nil
    end
  end

  defp aget(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp aget(_map, _key), do: nil

  @doc """
  PATCH /v1/conversations/:id/messages/:message_id  {body: "new text"} — edit a message.

  AUTHOR-ONLY, for BOTH actors. The message service's `authorize_author` gate (shared with the socket path)
  only lets the original sender edit; an app actor therefore edits AS a user it names via `sender` (the same
  external-id convention as create) and can still only touch THAT user's own messages. `:message_forbidden`
  (not your message) and "no such message" both collapse to **404** — same no-existence-reveal rule the rest
  of /v1 uses, and it also avoids telling an integrator that a message they can't touch exists.

  On success the updated message is broadcast on `conversation:<id>` as `message_updated` — the SAME event
  name + payload the socket path emits, so an already-connected first-party client updates live with no change.
  """
  def update(conn, %{"id" => conversation_id, "message_id" => message_id} = params) do
    app_id = conn.assigns.v1_app_id

    with {:ok, _conversation} <- ConversationAuthz.authorize_conversation(conn, conversation_id),
         {:ok, actor_user_id} <- resolve_sender(conn, app_id, params),
         {:ok, body} <- fetch_edit_body(params),
         {:ok, message} <-
           SharedInfra.MessageClient.update_message(%{
             "conversation_id" => conversation_id,
             "message_id" => message_id,
             "actor_user_id" => actor_user_id,
             "body" => body
           }) do
      fan_out_mutation(conversation_id, "message_updated", message)
      json(conn, message)
    else
      {:error, :invalid_body} -> ErrorResponse.invalid_request(conn, "v1.invalid_request")
      other -> mutation_error(conn, other)
    end
  end

  @doc """
  DELETE /v1/conversations/:id/messages/:message_id — SOFT-delete a message.

  Never a row removal: the service sets `status="deleted"` + `deleted_at`, so the message survives as a
  tombstone and threads/grouping don't develop gaps. Author-only for both actors (see `update/2`);
  not-yours / unknown / cross-tenant all → 404. Broadcasts `message_deleted` on `conversation:<id>` — again
  the socket path's exact event + tombstone payload.
  """
  def delete(conn, %{"id" => conversation_id, "message_id" => message_id} = params) do
    app_id = conn.assigns.v1_app_id

    with {:ok, _conversation} <- ConversationAuthz.authorize_conversation(conn, conversation_id),
         {:ok, actor_user_id} <- resolve_sender(conn, app_id, params),
         {:ok, message} <-
           SharedInfra.MessageClient.delete_message(%{
             "conversation_id" => conversation_id,
             "message_id" => message_id,
             "actor_user_id" => actor_user_id
           }) do
      fan_out_mutation(conversation_id, "message_deleted", message)
      json(conn, message)
    else
      other -> mutation_error(conn, other)
    end
  end

  # Not the author, no such message, or a cross-tenant/unknown conversation → an indistinguishable 404.
  defp mutation_error(conn, error) do
    case error do
      {:error, :message_unavailable} -> ErrorResponse.service_unavailable(conn, "v1.unavailable")
      {:error, :conversation_unavailable} -> ErrorResponse.service_unavailable(conn, "v1.unavailable")
      {:error, :message_forbidden} -> not_found(conn)
      {:error, :not_found} -> not_found(conn)
      {:error, :message_not_found} -> not_found(conn)
      {:error, :invalid_request} -> ErrorResponse.invalid_request(conn, "v1.invalid_request")
      _ -> not_found(conn)
    end
  end

  defp fetch_edit_body(params) do
    case Map.get(params, "body") do
      body when is_binary(body) and body != "" -> {:ok, body}
      _ -> {:error, :invalid_body}
    end
  end

  # Edit/delete broadcast on the CONVERSATION topic only — exactly what the socket's message:update /
  # message:delete do (they use broadcast_from on the conversation topic and do NOT mirror to user:<id>).
  # Deliberately NOT mirrored to user topics: the SDK routes both topics into the SAME channel and, unlike
  # `message_created`, updates/deletes are not de-duplicated by id — a mirror would emit message.updated /
  # message.deleted TWICE to any client watching the conversation. Fire-and-forget (never fails the request).
  defp fan_out_mutation(conversation_id, event, message) do
    Task.start(fn ->
      try do
        ApiGatewayWeb.Endpoint.broadcast("conversation:" <> conversation_id, event, message)
      rescue
        _ -> :ok
      end
    end)

    :ok
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
    media_id = media_id_param(params)

    SharedInfra.MessageClient.create_message(%{
      "conversation_id" => conversation_id,
      "sender_user_id" => sender_user_id,
      # A media attachment forces message_type "media" (the same vocabulary the socket path + frontend use);
      # otherwise honour the caller's type, defaulting to "text". `body` doubles as the media caption.
      "message_type" => if(media_id, do: "media", else: Map.get(params, "message_type", "text")),
      "media_id" => media_id,
      "body" => Map.get(params, "body"),
      # No object_key is injected into metadata for /v1 (it's inert legacy on the first-party path).
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
