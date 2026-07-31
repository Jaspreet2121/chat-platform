defmodule ApiGatewayWeb.V1.WebhookEndpointController do
  @moduledoc """
  Public `/v1` webhook-endpoint management for integrator SERVERS — authenticated by V1Auth with a
  SECRET KEY (`sk_live_…`/`sk_test_…`). The endpoint's app_id IS the key's resolved app_id
  (`conn.assigns.v1_app_id`), so a headless integrator self-serves webhooks for their own app with no
  OTP session. REQUIRES the secret-key actor — an end-user JWT may NOT manage webhooks (403 v1.app_only),
  mirroring `/v1/auth/token`.

  Reuses the SAME Webhooks context + signing-secret logic as the session route; only the auth + app_id
  source differ. Signing secret is returned ONCE on create; list/update/delete never expose it.
  """

  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  # POST /v1/webhooks/endpoints
  def create(conn, params) do
    with :ok <- require_app_actor(conn),
         {:ok, url} <- require_url(params),
         {:ok, endpoint} <-
           SharedInfra.AuthClient.create_webhook_endpoint(%{
             "app_id" => conn.assigns.v1_app_id,
             "url" => url,
             "event_types" => Map.get(params, "event_types")
           }) do
      conn
      |> put_status(:created)
      |> json(endpoint)
    else
      {:error, :forbidden} -> app_only(conn)
      {:error, :missing_url} -> ErrorResponse.invalid_request(conn, "v1.invalid_request")
      {:error, :auth_unavailable} -> ErrorResponse.service_unavailable(conn, "v1.unavailable")
      _ -> ErrorResponse.invalid_request(conn, "v1.invalid_request")
    end
  end

  # GET /v1/webhooks/endpoints
  def index(conn, _params) do
    with :ok <- require_app_actor(conn),
         {:ok, result} <-
           SharedInfra.AuthClient.list_webhook_endpoints(%{"app_id" => conn.assigns.v1_app_id}) do
      json(conn, result)
    else
      {:error, :forbidden} -> app_only(conn)
      {:error, :auth_unavailable} -> ErrorResponse.service_unavailable(conn, "v1.unavailable")
      _ -> ErrorResponse.invalid_request(conn, "v1.invalid_request")
    end
  end

  # PATCH /v1/webhooks/endpoints/:id
  def update(conn, %{"id" => id} = params) do
    with :ok <- require_app_actor(conn),
         {:ok, endpoint} <-
           SharedInfra.AuthClient.update_webhook_endpoint(%{
             "app_id" => conn.assigns.v1_app_id,
             "id" => id,
             "enabled" => Map.get(params, "enabled"),
             "event_types" => Map.get(params, "event_types")
           }) do
      json(conn, endpoint)
    else
      {:error, :forbidden} -> app_only(conn)
      {:error, :not_found} -> not_found(conn)
      {:error, :auth_unavailable} -> ErrorResponse.service_unavailable(conn, "v1.unavailable")
      _ -> ErrorResponse.invalid_request(conn, "v1.invalid_request")
    end
  end

  # DELETE /v1/webhooks/endpoints/:id
  def delete(conn, %{"id" => id}) do
    with :ok <- require_app_actor(conn),
         {:ok, result} <-
           SharedInfra.AuthClient.delete_webhook_endpoint(%{
             "app_id" => conn.assigns.v1_app_id,
             "id" => id
           }) do
      json(conn, result)
    else
      {:error, :forbidden} -> app_only(conn)
      {:error, :not_found} -> not_found(conn)
      {:error, :auth_unavailable} -> ErrorResponse.service_unavailable(conn, "v1.unavailable")
      _ -> ErrorResponse.invalid_request(conn, "v1.invalid_request")
    end
  end

  # Only a SECRET KEY may manage webhooks (an end-user JWT must not) — same guard as /v1/auth/token.
  defp require_app_actor(conn) do
    if conn.assigns[:v1_actor] == :app, do: :ok, else: {:error, :forbidden}
  end

  defp require_url(params) do
    case Map.get(params, "url") do
      url when is_binary(url) and url != "" -> {:ok, url}
      _ -> {:error, :missing_url}
    end
  end

  defp app_only(conn),
    do:
      ErrorResponse.forbidden(conn, "v1.app_only", "Only an API key may manage webhook endpoints")

  defp not_found(conn),
    do: ErrorResponse.not_found(conn, "v1.not_found", "Webhook endpoint not found")
end
