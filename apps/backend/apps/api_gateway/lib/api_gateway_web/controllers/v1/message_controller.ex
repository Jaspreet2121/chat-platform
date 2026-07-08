defmodule ApiGatewayWeb.V1.MessageController do
  @moduledoc """
  Public `/v1` message send + list — every request gated by the authenticated app_id. A conversation
  not in the caller's app returns 404 (never reveal cross-tenant existence). Send accepts an
  Idempotency-Key header so a retried POST returns the SAME message instead of duplicating.
  """

  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  def create(conn, %{"id" => conversation_id} = params) do
    app_id = conn.assigns.v1_app_id

    with {:ok, _conversation} <- conversation_in_app(conversation_id, app_id),
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
  # the end). The tenant gate (conversation_in_app) is unchanged.
  def index(conn, %{"id" => conversation_id} = params) do
    app_id = conn.assigns.v1_app_id

    with {:ok, _conversation} <- conversation_in_app(conversation_id, app_id),
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

  # ISOLATION GATE: the app_id is passed INTO the conversation lookup, which resolves the row only if
  # it belongs to the caller's app (an (app_id, id) predicate). A cross-tenant OR unknown id both
  # return not_found — indistinguishable to the caller, so we never confirm another tenant's resource
  # exists. app_id is server-derived (V1Auth → conn.assigns.v1_app_id); a body app_id can't reach it.
  defp conversation_in_app(conversation_id, app_id) do
    case SharedInfra.ConversationClient.get_conversation_app(%{
           "conversation_id" => conversation_id,
           "app_id" => app_id
         }) do
      {:ok, conversation} -> {:ok, conversation}
      _ -> {:error, :not_found}
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

  defp send_message(conn, app_id, conversation_id, sender_user_id, params) do
    case idempotency_key(conn) do
      nil ->
        do_send(conversation_id, sender_user_id, params)

      key ->
        case ApiGatewayWeb.V1Runtime.idem_get(app_id, conversation_id, key) do
          {:ok, message} ->
            {:ok, message}

          :miss ->
            with {:ok, message} <- do_send(conversation_id, sender_user_id, params) do
              ApiGatewayWeb.V1Runtime.idem_put(app_id, conversation_id, key, message)
              {:ok, message}
            end
        end
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
