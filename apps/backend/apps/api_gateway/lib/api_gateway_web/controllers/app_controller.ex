defmodule ApiGatewayWeb.AppController do
  @moduledoc """
  Self-serve integrator onboarding. A logged-in first-party user (OTP session) registers a business
  "app" and becomes its owner — the app gets a DISTINCT live app_id (not tenant-zero). The owner then
  issues keys / registers webhooks AS that app (authorized against app_owners). List returns the apps
  the caller owns so a client can pick which app to act as.
  """

  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  # POST /api/v1/apps (alias /api/v1/developer/apps) — register a new business app owned by the
  # caller. Returns {app_id, name, mode}. Capped per owner (default 3) → 403 app.limit_reached.
  def create(conn, params) do
    with {:ok, name} <- require_name(params),
         {:ok, session} <- app_session(conn),
         {:ok, app} <-
           SharedInfra.AuthClient.create_app(%{
             "owner_user_id" => session.user_id,
             "name" => name
           }) do
      conn
      |> put_status(:created)
      |> json(app)
    else
      {:error, :missing_name} ->
        ErrorResponse.invalid_request(conn, "app.name_required")

      {:error, :app_limit_reached} ->
        ErrorResponse.forbidden(
          conn,
          "app.limit_reached",
          "App limit reached for this account"
        )

      {:error, :session_invalid} ->
        session_invalid(conn)

      {:error, :auth_unavailable} ->
        service_unavailable(conn)

      _ ->
        ErrorResponse.invalid_request(conn, "app.invalid_request")
    end
  end

  # PATCH /api/v1/apps/:app_id — RENAME only (deletion/deactivation is a recorded follow-up; an app
  # owns live keys, webhooks, and tenant data — removal needs its own slice). Ownership is enforced
  # at the store (the UPDATE joins app_owners); not-owned/nonexistent/twin are the same 403 — no
  # existence leak.
  def update(conn, %{"app_id" => app_id} = params) do
    with {:ok, name} <- require_name(params),
         {:ok, session} <- app_session(conn),
         {:ok, app} <-
           SharedInfra.AuthClient.rename_app(%{
             "owner_user_id" => session.user_id,
             "app_id" => app_id,
             "name" => name
           }) do
      json(conn, app)
    else
      {:error, :missing_name} ->
        ErrorResponse.invalid_request(conn, "app.name_required")

      {:error, :forbidden} ->
        ErrorResponse.forbidden(conn, "app.forbidden", "Not an owner of this app")

      {:error, :session_invalid} ->
        session_invalid(conn)

      {:error, :auth_unavailable} ->
        service_unavailable(conn)

      _ ->
        ErrorResponse.invalid_request(conn, "app.invalid_request")
    end
  end

  # GET /api/v1/apps — list the apps the caller owns.
  def index(conn, _params) do
    with {:ok, session} <- app_session(conn),
         {:ok, result} <- SharedInfra.AuthClient.list_apps(%{"owner_user_id" => session.user_id}) do
      json(conn, result)
    else
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      _ -> ErrorResponse.invalid_request(conn, "app.invalid_request")
    end
  end

  defp app_session(conn) do
    with {:ok, authorization} <- authorization_header(conn) do
      SharedInfra.AuthClient.current_session(%{"authorization" => authorization})
    end
  end

  defp authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token = authorization] when token != "" -> {:ok, authorization}
      _ -> {:error, :session_invalid}
    end
  end

  defp require_name(params) do
    case Map.get(params, "name") do
      name when is_binary(name) and name != "" -> {:ok, name}
      _ -> {:error, :missing_name}
    end
  end

  defp session_invalid(conn),
    do: ErrorResponse.unauthorized(conn, "auth.session_invalid", "Session token is invalid")

  defp service_unavailable(conn),
    do: ErrorResponse.service_unavailable(conn, "app.unavailable")
end
