defmodule ApiGatewayWeb.AdminController do
  @moduledoc """
  Admin-only endpoints. The `ApiGatewayWeb.Plugs.RequireAdmin` plug has already verified the caller is
  a platform admin and stashed the session in `conn.assigns.admin_session`, so these handlers can trust
  it. Phase 0 only proves the gate end-to-end; analytics/moderation/health land in later phases.
  """
  use ApiGatewayWeb, :controller

  # Liveness for the admin surface — reachable only if the gate passed.
  def ping(conn, _params) do
    json(conn, %{ok: true})
  end

  # The authenticated admin's basic identity (smoke test for the gate).
  def me(conn, _params) do
    session = conn.assigns.admin_session

    json(conn, %{
      user_id: session.user_id,
      session_id: session.session_id,
      is_admin: true
    })
  end
end
