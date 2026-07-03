defmodule AuthService.HTTP.Router do
  @moduledoc """
  Internal HTTP API for auth-service (Plug, not Phoenix — the internal API is a few JSON routes).
  Routes map 1:1 to `SharedInfra.AuthClient`'s contract; each calls the in-process
  `AuthService.*` function and serializes via `SharedInfra.InternalApi.encode_result/1`, so the
  future HTTP client adapter reconstructs the exact in-process shape.

  Transport auth: `SharedInfra.InternalApi.TokenPlug` (requires `x-internal-token`). This listener
  is started ONLY under `AUTH_HTTP_API_ENABLED` (see `AuthService.Application`), default off, so the
  umbrella + plain `mix test` start no listener. All domain results are HTTP 200; the ok/error is
  carried in the body envelope. See docs/09-devops/INTERNAL_API.md.
  """
  use Plug.Router

  plug(SharedInfra.InternalApi.TokenPlug)
  plug(SharedInfra.InternalApi.CorrelationPlug)
  plug(:match)
  plug(Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
  plug(:dispatch)

  post "/internal/sessions/current" do
    send_result(conn, AuthService.Sessions.current_session(body(conn)))
  end

  get "/internal/sessions/persistence_enabled" do
    send_result(conn, AuthService.Sessions.persistence_enabled?())
  end

  post "/internal/otp/request" do
    send_result(conn, AuthService.OTP.request_otp(body(conn)))
  end

  post "/internal/otp/verify" do
    send_result(conn, AuthService.OTP.verify_otp(body(conn)))
  end

  post "/internal/tokens/refresh" do
    send_result(conn, AuthService.Tokens.refresh(body(conn)))
  end

  post "/internal/tokens/revoke" do
    send_result(conn, AuthService.Tokens.revoke(body(conn)))
  end

  # Phone → user_id resolution for WhatsApp-style direct chat. Active-only; the gateway gates this
  # behind a valid session before calling (the transport TokenPlug above is service-to-service auth).
  post "/internal/users/by_phone" do
    send_result(
      conn,
      AuthService.Accounts.lookup_active_by_phone(Map.get(body(conn), "phone_number"))
    )
  end

  # Secret API keys (per app). Management routes are gated upstream by the gateway behind app-owner
  # auth; verify is called by the gateway's /v1 secret-key plug. The raw key is never logged here.
  # Self-serve integrator apps — the gateway gates these behind an app-owner session; ownership authz
  # (owns_app) is enforced here before any app-scoped action acts AS a given app_id.
  post "/internal/apps/create" do
    send_result(conn, AuthService.Apps.create_app(body(conn)))
  end

  post "/internal/apps/list" do
    send_result(conn, AuthService.Apps.list_apps(body(conn)))
  end

  post "/internal/apps/owns" do
    send_result(conn, AuthService.Apps.owns_app(body(conn)))
  end

  post "/internal/api_keys/create" do
    send_result(conn, AuthService.ApiKeys.create_api_key(body(conn)))
  end

  post "/internal/api_keys/list" do
    send_result(conn, AuthService.ApiKeys.list_api_keys(body(conn)))
  end

  post "/internal/api_keys/revoke" do
    send_result(conn, AuthService.ApiKeys.revoke_api_key(body(conn)))
  end

  post "/internal/api_keys/verify" do
    send_result(conn, AuthService.ApiKeys.verify_api_key(Map.get(body(conn), "api_key")))
  end

  # End-user token-exchange (gateway gates create behind a verified secret key; verify is used by the
  # /v1 plug + the socket to authenticate end-user JWTs). Single crypto path: AuthService.Tokens.
  post "/internal/app_auth/token" do
    send_result(conn, AuthService.AppAuth.mint_app_user_token(body(conn)))
  end

  post "/internal/app_auth/resolve_user" do
    send_result(conn, AuthService.AppAuth.resolve_external_user(body(conn)))
  end

  post "/internal/app_auth/verify_token" do
    send_result(conn, AuthService.AppAuth.verify_app_user_token(Map.get(body(conn), "token")))
  end

  # Webhook endpoint management (gateway gates these behind app-owner auth; app_id from the session).
  post "/internal/webhooks/endpoints/create" do
    send_result(conn, AuthService.Webhooks.create_endpoint(body(conn)))
  end

  post "/internal/webhooks/endpoints/list" do
    send_result(conn, AuthService.Webhooks.list_endpoints(body(conn)))
  end

  post "/internal/webhooks/endpoints/update" do
    send_result(conn, AuthService.Webhooks.update_endpoint(body(conn)))
  end

  post "/internal/webhooks/endpoints/delete" do
    send_result(conn, AuthService.Webhooks.delete_endpoint(body(conn)))
  end

  # Failed-delivery ops (Phase 4) — gateway gates these behind an ADMIN session; actor is the admin.
  post "/internal/webhooks/outbox/failed" do
    send_result(conn, AuthService.Webhooks.list_failed_deliveries(body(conn)))
  end

  post "/internal/webhooks/outbox/reenqueue" do
    send_result(conn, AuthService.Webhooks.reenqueue_delivery(body(conn)))
  end

  post "/internal/webhooks/outbox/reenqueue_bulk" do
    send_result(conn, AuthService.Webhooks.reenqueue_deliveries_bulk(body(conn)))
  end

  # --- Admin moderation (gated upstream by the gateway's RequireAdmin + this internal TokenPlug) ---
  post "/internal/admin/users/list" do
    send_result(conn, {:ok, AuthService.Accounts.list_users(body(conn))})
  end

  post "/internal/admin/users/get" do
    send_result(conn, AuthService.Moderation.user_detail(body(conn)))
  end

  post "/internal/admin/users/suspend" do
    send_result(conn, AuthService.Moderation.suspend_user(body(conn)))
  end

  post "/internal/admin/users/reactivate" do
    send_result(conn, AuthService.Moderation.reactivate_user(body(conn)))
  end

  post "/internal/admin/users/ban" do
    send_result(conn, AuthService.Moderation.ban_user(body(conn)))
  end

  post "/internal/admin/users/role" do
    send_result(conn, AuthService.Moderation.set_role(body(conn)))
  end

  post "/internal/admin/users/delete" do
    send_result(conn, AuthService.Moderation.delete_user(body(conn)))
  end

  post "/internal/admin/reports/list" do
    send_result(conn, AuthService.Moderation.list_reports(body(conn)))
  end

  post "/internal/admin/reports/update" do
    send_result(conn, AuthService.Moderation.update_report(body(conn)))
  end

  post "/internal/admin/audit/write" do
    send_result(conn, AuthService.Moderation.write_audit(body(conn)))
  end

  post "/internal/admin/audit/list" do
    send_result(conn, AuthService.Moderation.list_audit(body(conn)))
  end

  get "/internal/health" do
    send_result(conn, {:ok, %{service: "auth", status: "ok", deps: %{}}})
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{"error" => "not_found"}))
  end

  defp body(%{body_params: params}) when is_map(params) and not is_struct(params), do: params
  defp body(_conn), do: %{}

  defp send_result(conn, result) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(SharedInfra.InternalApi.encode_result(result)))
  end
end
