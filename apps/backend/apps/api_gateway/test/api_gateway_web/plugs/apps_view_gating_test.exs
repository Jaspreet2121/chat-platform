defmodule ApiGatewayWeb.Plugs.AppsViewGatingTest do
  @moduledoc """
  The gating for the two new Surface-3 pages, at the enforcement layer (`RequirePermission` — the plug
  AdminAppsController and AdminWebhookController run). Pins the IAM scheme's answer to "who sees these":

    * `apps.view` / `webhooks.view` — root, admin, AND support (the read-only console role by design);
      moderator has neither.
    * `webhooks.manage` (re-enqueue mutations) — root and admin ONLY.

  Permissions are derived from the role exactly as the plug does in production (session → IAM fallback).
  """
  use ExUnit.Case, async: true

  import Plug.Test

  alias ApiGatewayWeb.Plugs.RequirePermission

  defp conn_with_role(role) do
    :get
    |> conn("/api/v1/admin/apps")
    |> Plug.Conn.assign(:admin_session, %{
      user_id: "u1",
      role: role,
      permissions: SharedInfra.IAM.permissions_for(role)
    })
  end

  defp allowed?(role, permission) do
    conn = RequirePermission.call(conn_with_role(role), RequirePermission.init(permission))
    not conn.halted
  end

  test "apps.view — root/admin/support pass; moderator is refused" do
    assert allowed?("root", "apps.view")
    assert allowed?("admin", "apps.view")
    assert allowed?("support", "apps.view")
    refute allowed?("moderator", "apps.view")
  end

  test "webhooks.view — root/admin/support pass; moderator is refused" do
    assert allowed?("root", "webhooks.view")
    assert allowed?("admin", "webhooks.view")
    assert allowed?("support", "webhooks.view")
    refute allowed?("moderator", "webhooks.view")
  end

  test "webhooks.manage (re-enqueue) — root/admin ONLY; support and moderator are refused" do
    assert allowed?("root", "webhooks.manage")
    assert allowed?("admin", "webhooks.manage")
    refute allowed?("support", "webhooks.manage")
    refute allowed?("moderator", "webhooks.manage")
  end

  test "a refusal is a 403 with the standard envelope" do
    conn =
      RequirePermission.call(conn_with_role("moderator"), RequirePermission.init("apps.view"))

    assert conn.halted
    assert conn.status == 403
  end
end
