defmodule ApiGatewayWeb.AdminWebhookController do
  @moduledoc """
  Admin recovery/inspection surface for dead-lettered webhook deliveries. Gated by the existing
  RequireAdmin pipeline (verified admin session; actor = admin_session.user_id, recorded in the audit
  log). Keyset-paginated failed list + idempotent single / capped bulk re-enqueue.
  """

  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  # GET /api/v1/admin/webhooks/outbox/failed?app_id=&event_type=&limit=&cursor=
  def failed(conn, params) do
    {cursor_ts, cursor_id} = decode_cursor(Map.get(params, "cursor"))

    attrs =
      drop_nils(%{
        "app_id" => Map.get(params, "app_id"),
        "event_type" => Map.get(params, "event_type"),
        "limit" => Map.get(params, "limit"),
        "cursor_ts" => cursor_ts,
        "cursor_id" => cursor_id,
        "actor" => actor(conn)
      })

    case SharedInfra.AuthClient.list_failed_webhooks(attrs) do
      {:ok, result} ->
        json(conn, %{
          data: get(result, :items) || [],
          count: get(result, :count) || 0,
          next_cursor: encode_cursor(get(result, :next_cursor))
        })

      {:error, :auth_unavailable} ->
        ErrorResponse.service_unavailable(conn, "webhook.unavailable")

      _ ->
        ErrorResponse.invalid_request(conn, "webhook.invalid_request")
    end
  end

  # POST /api/v1/admin/webhooks/outbox/:id/reenqueue
  def reenqueue(conn, %{"id" => id}) do
    case SharedInfra.AuthClient.reenqueue_webhook(%{"id" => id, "actor" => actor(conn)}) do
      {:ok, result} ->
        case get(result, :status) do
          "reenqueued" -> conn |> put_status(:accepted) |> json(result)
          "noop" -> conn |> put_status(:conflict) |> json(result)
          _ -> conn |> put_status(:accepted) |> json(result)
        end

      {:error, :auth_unavailable} ->
        ErrorResponse.service_unavailable(conn, "webhook.unavailable")

      _ ->
        ErrorResponse.invalid_request(conn, "webhook.invalid_request")
    end
  end

  # POST /api/v1/admin/webhooks/outbox/reenqueue_bulk?app_id=&event_type=&limit=
  def reenqueue_bulk(conn, params) do
    attrs =
      drop_nils(%{
        "app_id" => Map.get(params, "app_id"),
        "event_type" => Map.get(params, "event_type"),
        "limit" => Map.get(params, "limit"),
        "actor" => actor(conn)
      })

    case SharedInfra.AuthClient.reenqueue_webhooks_bulk(attrs) do
      {:ok, result} ->
        conn |> put_status(:accepted) |> json(result)

      {:error, :auth_unavailable} ->
        ErrorResponse.service_unavailable(conn, "webhook.unavailable")

      _ ->
        ErrorResponse.invalid_request(conn, "webhook.invalid_request")
    end
  end

  defp actor(conn), do: conn.assigns.admin_session.user_id

  defp get(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp get(_map, _key), do: nil

  defp drop_nils(map), do: :maps.filter(fn _k, v -> not is_nil(v) end, map)

  # Opaque base64 keyset cursor over "created_at|id".
  defp encode_cursor(nil), do: nil

  defp encode_cursor(next) when is_map(next) do
    ts = get(next, :created_at)
    id = get(next, :id)

    if is_binary(ts) and is_binary(id),
      do: Base.url_encode64("#{ts}|#{id}", padding: false),
      else: nil
  end

  defp encode_cursor(_), do: nil

  defp decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, raw} <- Base.url_decode64(cursor, padding: false),
         [ts, id] <- String.split(raw, "|", parts: 2) do
      {ts, id}
    else
      _ -> {nil, nil}
    end
  end

  defp decode_cursor(_), do: {nil, nil}
end
