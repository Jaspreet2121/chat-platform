defmodule ApiGatewayWeb.AdminAppsController do
  @moduledoc """
  Surface-3 cross-tenant Apps overview: every registered app with owner identity, usage counts, and
  key/webhook aggregates — the operator view (and the read-only base billing will later consume).

  Gated `apps.view` per the IAM scheme: root/admin/support can read (support is the read-only console role by
  design — see SharedInfra.IAM @support_view); moderator cannot. The service layer never selects key hashes,
  prefixes, or signing secrets, so there is nothing sensitive to strip here.
  """
  use ApiGatewayWeb, :controller

  plug ApiGatewayWeb.Plugs.RequirePermission, "apps.view"

  alias ApiGatewayWeb.ErrorResponse

  # GET /api/v1/admin/apps/:id/usage?period=YYYY-MM — the PERIOD meter for one app (defaults to the
  # current UTC month). Reuses the exact fn the owner endpoint uses, so operator and owner can never see
  # different numbers for the same month. Chosen over widening the batched overview: billing needs
  # ARBITRARY months, which current-month columns can't give, and the overview payload stays lean.
  def usage(conn, %{"id" => app_id} = params) do
    period = Map.get(params, "period") || current_period()

    case SharedInfra.AuthClient.app_usage_period(%{"app_id" => app_id, "period" => period}) do
      {:ok, usage} ->
        json(conn, usage)

      {:error, :invalid_period} ->
        ErrorResponse.unprocessable_entity(
          conn,
          "admin.invalid_period",
          ~s(period must be "YYYY-MM" and not in the future)
        )

      {:error, :auth_unavailable} ->
        ErrorResponse.service_unavailable(conn, "admin.unavailable")

      _ ->
        ErrorResponse.invalid_request(conn, "admin.invalid_request")
    end
  end

  defp current_period do
    now = DateTime.utc_now()
    "#{now.year}-#{String.pad_leading(Integer.to_string(now.month), 2, "0")}"
  end

  # GET /api/v1/admin/apps?q= — cross-tenant app list (live apps as rows; the test twin is a badge).
  def index(conn, params) do
    case SharedInfra.AuthClient.admin_list_apps(%{"q" => Map.get(params, "q")}) do
      {:ok, result} -> json(conn, result)
      {:error, :auth_unavailable} -> ErrorResponse.service_unavailable(conn, "admin.unavailable")
      _ -> ErrorResponse.invalid_request(conn, "admin.invalid_request")
    end
  end
end
