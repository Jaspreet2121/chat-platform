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

  # GET /api/v1/admin/apps?q= — cross-tenant app list (live apps as rows; the test twin is a badge).
  def index(conn, params) do
    case SharedInfra.AuthClient.admin_list_apps(%{"q" => Map.get(params, "q")}) do
      {:ok, result} -> json(conn, result)
      {:error, :auth_unavailable} -> ErrorResponse.service_unavailable(conn, "admin.unavailable")
      _ -> ErrorResponse.invalid_request(conn, "admin.invalid_request")
    end
  end
end
