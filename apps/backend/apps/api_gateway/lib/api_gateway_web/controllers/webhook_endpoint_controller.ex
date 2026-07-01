defmodule ApiGatewayWeb.WebhookEndpointController do
  @moduledoc """
  App-owner management of webhook endpoints. Gated by the EXISTING app session (logged-in app owner) —
  the endpoint's app is the caller's session app_id. The signing secret is returned ONCE on create;
  list/update/delete never expose it.
  """

  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  # POST /api/v1/webhooks/endpoints — register a URL; returns the signing secret ONCE.
  def create(conn, params) do
    with {:ok, url} <- require_url(params),
         {:ok, session} <- app_session(conn),
         {:ok, endpoint} <-
           SharedInfra.AuthClient.create_webhook_endpoint(%{
             "app_id" => session.app_id,
             "url" => url,
             "event_types" => Map.get(params, "event_types")
           }) do
      conn
      |> put_status(:created)
      |> json(endpoint)
    else
      {:error, :missing_url} -> ErrorResponse.invalid_request(conn, "webhook.url_required")
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      _ -> ErrorResponse.invalid_request(conn, "webhook.invalid_request")
    end
  end

  # GET /api/v1/webhooks/endpoints — list this app's endpoints (never the signing secret).
  def index(conn, _params) do
    with {:ok, session} <- app_session(conn),
         {:ok, result} <-
           SharedInfra.AuthClient.list_webhook_endpoints(%{"app_id" => session.app_id}) do
      json(conn, result)
    else
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      _ -> ErrorResponse.invalid_request(conn, "webhook.invalid_request")
    end
  end

  # PATCH /api/v1/webhooks/endpoints/:id — enable/disable or change event_types.
  def update(conn, %{"id" => id} = params) do
    with {:ok, session} <- app_session(conn),
         {:ok, endpoint} <-
           SharedInfra.AuthClient.update_webhook_endpoint(%{
             "app_id" => session.app_id,
             "id" => id,
             "enabled" => Map.get(params, "enabled"),
             "event_types" => Map.get(params, "event_types")
           }) do
      json(conn, endpoint)
    else
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :not_found} -> not_found(conn)
      _ -> ErrorResponse.invalid_request(conn, "webhook.invalid_request")
    end
  end

  # DELETE /api/v1/webhooks/endpoints/:id
  def delete(conn, %{"id" => id}) do
    with {:ok, session} <- app_session(conn),
         {:ok, result} <-
           SharedInfra.AuthClient.delete_webhook_endpoint(%{
             "app_id" => session.app_id,
             "id" => id
           }) do
      json(conn, result)
    else
      {:error, :session_invalid} -> session_invalid(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :not_found} -> not_found(conn)
      _ -> ErrorResponse.invalid_request(conn, "webhook.invalid_request")
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

  defp require_url(params) do
    case Map.get(params, "url") do
      url when is_binary(url) and url != "" -> {:ok, url}
      _ -> {:error, :missing_url}
    end
  end

  defp session_invalid(conn),
    do: ErrorResponse.unauthorized(conn, "auth.session_invalid", "Session token is invalid")

  defp service_unavailable(conn),
    do: ErrorResponse.service_unavailable(conn, "webhook.unavailable")

  defp not_found(conn),
    do: ErrorResponse.not_found(conn, "webhook.not_found", "Webhook endpoint not found")
end
