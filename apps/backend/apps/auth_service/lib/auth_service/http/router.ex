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

  # --- Admin moderation (gated upstream by the gateway's RequireAdmin + this internal TokenPlug) ---
  post "/internal/admin/users/list" do
    send_result(conn, {:ok, AuthService.Accounts.list_users(body(conn))})
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
