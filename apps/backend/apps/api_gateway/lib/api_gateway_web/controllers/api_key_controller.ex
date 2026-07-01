defmodule ApiGatewayWeb.ApiKeyController do
  @moduledoc """
  App-owner management of secret API keys (the integrator's server credential for `/v1`). Gated by the
  EXISTING app session. The key's app is resolved from an OPTIONAL `app_id` param the caller must OWN
  (authorized against app_owners) — so an owner issues keys AS their registered app (distinct live
  app_id), not tenant-zero. With no `app_id` (or the default app), it falls back to the session's app_id
  = tenant-zero, exactly as before (backward-compat for first-party users without a registered app). A
  test key derives its per-app twin off whichever app_id is resolved. Raw key returned ONCE on create.
  """

  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  # POST /api/v1/api-keys — create a key; returns the full `sk_…` ONCE (store it now).
  def create(conn, params) do
    with {:ok, name} <- require_name(params),
         {:ok, mode} <- require_mode(params),
         {:ok, session} <- app_session(conn),
         {:ok, app_id} <- resolve_target_app(session, params),
         {:ok, key} <-
           SharedInfra.AuthClient.create_api_key(%{
             "app_id" => app_id,
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
      {:error, :not_owner} -> forbidden_app(conn)
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      _ -> ErrorResponse.invalid_request(conn, "api_key.invalid_request")
    end
  end

  # Resolve the app_id to act AS: the optional `app_id` param, which the caller must OWN (or the default
  # app, which stays open for backward-compat); no param → the session's app_id (tenant-zero). A caller
  # can NEVER act as an app_id they don't own → {:error, :not_owner}.
  defp resolve_target_app(session, params) do
    case presence(Map.get(params, "app_id")) do
      nil ->
        {:ok, session.app_id}

      requested ->
        if requested == SharedInfra.Tenancy.default_app_id() do
          {:ok, requested}
        else
          case SharedInfra.AuthClient.owns_app(%{
                 "owner_user_id" => session.user_id,
                 "app_id" => requested
               }) do
            {:ok, _} -> {:ok, requested}
            _ -> {:error, :not_owner}
          end
        end
    end
  end

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_), do: nil

  defp forbidden_app(conn),
    do: ErrorResponse.forbidden(conn, "api_key.forbidden_app", "You do not own this app")

  # mode is optional; defaults to "live". Only "live"/"test" accepted.
  defp require_mode(params) do
    case Map.get(params, "mode") do
      nil -> {:ok, "live"}
      mode when mode in ["live", "test"] -> {:ok, mode}
      _ -> {:error, :invalid_mode}
    end
  end

  # GET /api/v1/api-keys — list this app's keys (prefix + metadata only, never the secret). Same
  # app-resolution as create: optional owned `app_id`, else the session default (tenant-zero).
  def index(conn, params) do
    with {:ok, session} <- app_session(conn),
         {:ok, app_id} <- resolve_target_app(session, params),
         {:ok, result} <- SharedInfra.AuthClient.list_api_keys(%{"app_id" => app_id}) do
      json(conn, result)
    else
      {:error, :not_owner} -> forbidden_app(conn)
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      _ -> ErrorResponse.invalid_request(conn, "api_key.invalid_request")
    end
  end

  # DELETE /api/v1/api-keys/:id — revoke one of this app's keys (scoped to the resolved owned app).
  def revoke(conn, %{"id" => id} = params) do
    with {:ok, session} <- app_session(conn),
         {:ok, app_id} <- resolve_target_app(session, params),
         {:ok, result} <-
           SharedInfra.AuthClient.revoke_api_key(%{"app_id" => app_id, "id" => id}) do
      json(conn, result)
    else
      {:error, :not_owner} ->
        forbidden_app(conn)

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
