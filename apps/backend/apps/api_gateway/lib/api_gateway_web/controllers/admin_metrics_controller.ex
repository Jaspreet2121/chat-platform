defmodule ApiGatewayWeb.AdminMetricsController do
  @moduledoc """
  LAYER 3 query surface — per-app usage metrics (NOT a dashboard; just queryable data a future
  Grafana/Datadog can also consume). Admin-gated by the `:admin_required` pipeline. Reads the
  observability store via the gateway's raw-Postgrex connection; fail-open (empty lists on any failure).

  `GET /api/v1/admin/metrics?hours=24` →
    { window_hours, requests: [{app_id, route, count}], webhooks_delivered: [{app_id, count}],
      errors: [{app_id, count}] }
  """

  use ApiGatewayWeb, :controller

  plug ApiGatewayWeb.Plugs.RequirePermission, "platform.view"

  def show(conn, params) do
    hours = parse_hours(Map.get(params, "hours"))

    metrics =
      SharedInfra.Observability.metrics(ApiGateway.Application.observability_db(), hours: hours)

    json(conn, Map.put(metrics, :window_hours, hours))
  end

  defp parse_hours(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n > 0 and n <= 24 * 30 -> n
      _ -> 24
    end
  end

  defp parse_hours(_), do: 24
end
