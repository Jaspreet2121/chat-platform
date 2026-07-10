defmodule ApiGatewayWeb.AdminAnalyticsController do
  @moduledoc """
  Read-only admin analytics. Gated by `ApiGatewayWeb.Plugs.RequireAdmin` (already verified the caller
  is a platform admin). Proxies to the message service's analytics read module via the message client;
  a transport/query failure maps to 503 with the standard envelope.
  """
  use ApiGatewayWeb, :controller

  plug ApiGatewayWeb.Plugs.RequirePermission, "platform.view"

  alias ApiGatewayWeb.ErrorResponse

  def overview(conn, _params) do
    case SharedInfra.MessageClient.analytics_overview(%{"app_id" => SharedInfra.Tenancy.default_app_id()}) do
      {:ok, data} -> json(conn, data)
      {:error, _reason} -> unavailable(conn)
    end
  end

  # FIRST-PARTY ONLY: counts are tenant-zero, never the whole platform. Cross-tenant per-app usage is a
  # separate future ops route. app_id comes from the single source (SharedInfra.Tenancy.default_app_id/0).
  def timeseries(conn, params) do
    case SharedInfra.MessageClient.analytics_timeseries(%{
           "days" => params["days"] || "30",
           "app_id" => SharedInfra.Tenancy.default_app_id()
         }) do
      {:ok, data} -> json(conn, data)
      {:error, _reason} -> unavailable(conn)
    end
  end

  defp unavailable(conn),
    do: ErrorResponse.service_unavailable(conn, "admin.analytics_unavailable")
end
