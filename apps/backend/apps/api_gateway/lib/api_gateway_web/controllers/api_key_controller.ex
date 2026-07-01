defmodule ApiGatewayWeb.ApiKeyController do
  @moduledoc """
  App-owner management of secret API keys (the integrator's server credential for `/v1`). Gated by the
  EXISTING app session (a logged-in app owner) — the key's app is the caller's session app_id. The raw
  key is returned ONCE on create; list/revoke never expose the secret.
  """

  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  # POST /api/v1/api-keys — create a key; returns the full `sk_live_…` ONCE (store it now).
  def create(conn, params) do
    with {:ok, name} <- require_name(params),
         {:ok, mode} <- require_mode(params),
         {:ok, session} <- app_session(conn),
         {:ok, key} <-
           SharedInfra.AuthClient.create_api_key(%{
             "app_id" => session.app_id,
             "name" => name,
             # "test" issues an sk_test_ key against the integrator's test-twin app_id; default "live".
             "mode" => mode
           }) do
      conn
      |> put_status(:created)
      |> json(key)
    else
      {:error, :missing_name} -> ErrorResponse.invalid_request(conn, "api_key.name_required")
      {:error, :invalid_mode} -> ErrorResponse.invalid_request(conn, "api_key.invalid_mode")
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      _ -> ErrorResponse.invalid_request(conn, "api_key.invalid_request")
    end
  end

  # mode is optional; defaults to "live". Only "live"/"test" accepted.
  defp require_mode(params) do
    case Map.get(params, "mode") do
      nil -> {:ok, "live"}
      mode when mode in ["live", "test"] -> {:ok, mode}
      _ -> {:error, :invalid_mode}
    end
  end

  # GET /api/v1/api-keys — list this app's keys (prefix + metadata only, never the secret).
  def index(conn, _params) do
    with {:ok, session} <- app_session(conn),
         {:ok, result} <- SharedInfra.AuthClient.list_api_keys(%{"app_id" => session.app_id}) do
      json(conn, result)
    else
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      _ -> ErrorResponse.invalid_request(conn, "api_key.invalid_request")
    end
  end

  # DELETE /api/v1/api-keys/:id — revoke one of this app's keys.
  def revoke(conn, %{"id" => id}) do
    with {:ok, session} <- app_session(conn),
         {:ok, result} <-
           SharedInfra.AuthClient.revoke_api_key(%{"app_id" => session.app_id, "id" => id}) do
      json(conn, result)
    else
      {:error, :session_invalid} ->
        session_invalid(conn)

      {:error, :auth_unavailable} ->
        service_unavailable(conn)

      {:error, :not_found} ->
        ErrorResponse.not_found(conn, "api_key.not_found", "API key not found")

      _ ->
        ErrorResponse.invalid_request(conn, "api_key.invalid_request")
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
    do: ErrorResponse.service_unavailable(conn, "api_key.unavailable")
end
