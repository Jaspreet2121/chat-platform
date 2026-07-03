defmodule ApiGatewayWeb.Plugs.RequirePermission do
  @moduledoc """
  Per-route capability gate (IAM Phase 1). A CONTROLLER plug that authorizes a single permission against
  the admin session `ApiGatewayWeb.Plugs.RequireAdmin` already resolved into `conn.assigns.admin_session`.

      plug ApiGatewayWeb.Plugs.RequirePermission, "users.moderate" when action in [:suspend_user, ...]

  Returns 403 (`admin.forbidden`) when the caller's role lacks the permission. The permissions come off
  the session payload (resolved server-side from the DB user's role); as belt-and-suspenders it
  re-derives them from the session `role` via `SharedInfra.IAM` if the list is absent.
  """

  import Plug.Conn

  alias ApiGatewayWeb.ErrorResponse

  def init(permission) when is_binary(permission), do: permission

  def call(conn, permission) do
    session = conn.assigns[:admin_session] || %{}

    permissions =
      Map.get(session, :permissions) || SharedInfra.IAM.permissions_for(Map.get(session, :role))

    if permission in permissions do
      conn
    else
      conn
      |> ErrorResponse.forbidden("admin.forbidden", "Requires permission: #{permission}")
      |> halt()
    end
  end
end
