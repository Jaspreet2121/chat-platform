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

  # GET /api/v1/usage → {app_id, users, conversations, messages, storage_bytes}          (lifetime, as ever)
  # GET /api/v1/usage?period=YYYY-MM → the PERIOD meter instead: {messages_sent,
  #   active_users_by_messages, call_seconds, storage_bytes_snapshot, period_start/end}. Additive — the
  #   parameterless response is byte-identical to before. Malformed or not-yet-started period → 422.
  def index(conn, params) do
    with {:ok, _session, app_id} <- AppOwnerAuth.resolve_owned_app(conn, params),
         {:ok, usage} <- fetch_usage(app_id, Map.get(params, "period")) do
      json(conn, usage)
    else
      {:error, :invalid_period} ->
        ErrorResponse.unprocessable_entity(
          conn,
          "usage.invalid_period",
          ~s(period must be "YYYY-MM" and not in the future)
        )

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

  # No period → the lifetime counts (unchanged contract). With a period → the monthly meter.
  defp fetch_usage(app_id, nil), do: SharedInfra.AuthClient.app_usage(%{"app_id" => app_id})

  defp fetch_usage(app_id, period),
    do: SharedInfra.AuthClient.app_usage_period(%{"app_id" => app_id, "period" => period})
end
