defmodule ApiGatewayWeb.AdminWebhookController do
  @moduledoc """
  Admin recovery/inspection surface for dead-lettered webhook deliveries. Gated by the existing
  RequireAdmin pipeline (verified admin session; actor = admin_session.user_id, recorded in the audit
  log). Keyset-paginated failed list + idempotent single / capped bulk re-enqueue.
  """

  use ApiGatewayWeb, :controller

  # Read-only dead-letter inspection = webhooks.view; the reenqueue MUTATIONS = webhooks.manage
  # (root/admin only) — a mutation shouldn't ride a view permission.
  plug ApiGatewayWeb.Plugs.RequirePermission, "webhooks.view" when action in [:failed]

  plug ApiGatewayWeb.Plugs.RequirePermission,
       "webhooks.manage"
       when action in [:reenqueue, :reenqueue_bulk]

  alias ApiGatewayWeb.ErrorResponse

  # GET /api/v1/admin/webhooks/outbox/failed?app_id=&event_type=&limit=&cursor=
  def failed(conn, params) do
    attrs =
      drop_nils(%{
        "app_id" => Map.get(params, "app_id"),
        "event_type" => Map.get(params, "event_type"),
        "page" => Map.get(params, "page"),
        "page_size" => Map.get(params, "page_size"),
        "actor" => actor(conn)
      })

    case SharedInfra.AuthClient.list_failed_webhooks(attrs) do
      {:ok, result} ->
        json(conn, %{
          data: get(result, :items) || [],
          page: get(result, :page),
          page_size: get(result, :page_size),
          total: get(result, :total),
          total_pages: get(result, :total_pages)
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
end
