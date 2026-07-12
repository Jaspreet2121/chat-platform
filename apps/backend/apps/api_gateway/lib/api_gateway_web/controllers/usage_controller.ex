defmodule ApiGatewayWeb.UsageController do
  @moduledoc """
  Owner-facing USAGE for one owned app — the counts the integrator dashboard shows.

  `GET /api/v1/usage?app_id=` (logged-in first-party owner session). The `app_id` must be one the caller
  OWNS (`ApiGatewayWeb.AppOwnerAuth` — the same gate as `/api-keys` and `/webhooks/endpoints`); a
  not-owned app → 403. Omitted → the session's default app.

  Every field is a REAL query — nothing is estimated. Entity counts only; no message content is read and
  nothing is cross-tenant (each query is `WHERE app_id = <owned app>`; messages scope via their parent
  conversation, which is a message's authoritative tenant).

  This is DELIBERATELY not on `/v1` — `/v1` is the integrator's end-user/secret-key API. This is the owner
  console, alongside /apps, /api-keys and /webhooks/*.
  """

  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.AppOwnerAuth
  alias ApiGatewayWeb.ErrorResponse

  # GET /api/v1/usage → {app_id, users, conversations, messages, storage_bytes}
  def index(conn, params) do
    with {:ok, _session, app_id} <- AppOwnerAuth.resolve_owned_app(conn, params),
         {:ok, usage} <- SharedInfra.AuthClient.app_usage(%{"app_id" => app_id}) do
      json(conn, usage)
    else
      {:error, :not_owner} ->
        ErrorResponse.forbidden(conn, "usage.forbidden_app", "You do not own this app")

      {:error, :session_invalid} ->
        ErrorResponse.unauthorized(conn, "auth.session_invalid", "Session token is invalid")

      {:error, :auth_unavailable} ->
        ErrorResponse.service_unavailable(conn, "usage.unavailable")

      _ ->
        ErrorResponse.invalid_request(conn, "usage.invalid_request")
    end
  end
end
