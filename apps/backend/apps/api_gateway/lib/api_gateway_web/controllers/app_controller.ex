defmodule ApiGatewayWeb.AppController do
  @moduledoc """
  Self-serve integrator onboarding. A logged-in first-party user (OTP session) registers a business
  "app" and becomes its owner — the app gets a DISTINCT live app_id (not tenant-zero). The owner then
  issues keys / registers webhooks AS that app (authorized against app_owners). List returns the apps
  the caller owns so a client can pick which app to act as.
  """

  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  # POST /api/v1/apps — register a new business app owned by the caller. Returns {app_id, name, mode}.
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
      {:error, :missing_name} -> ErrorResponse.invalid_request(conn, "app.name_required")
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      _ -> ErrorResponse.invalid_request(conn, "app.invalid_request")
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
