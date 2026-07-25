defmodule SharedInfra.AuthClientHttp do
  @moduledoc """
  HTTP adapter for `SharedInfra.AuthClient` — calls auth-service's internal HTTP API over the
  network (`AuthService.HTTP.Router`) instead of in-process. Selected by `AUTH_CLIENT_ADAPTER=http`;
  the default stays `AuthService.AuthClientInProcess` (zero behavior change until flipped).

  Lives in shared_infra (NOT auth_service) because the gateway/realtime containers depend on
  shared_infra but will NOT include auth_service after the split. Shapes are reconstructed via
  `SharedInfra.InternalApi.decode_result/1` (through `SharedInfra.HttpClient`), so HTTP results equal
  the in-process results EXACTLY (incl. `current_session`'s atom-keyed map + preserved error atoms).
  Transport failures map to `{:error, :auth_unavailable}` (the gateway maps that to HTTP 503).

  Base URL from `AUTH_SERVICE_URL` (`:shared_infra, :auth_service_url`), token from `INTERNAL_API_TOKEN`.
  """

  @behaviour SharedInfra.AuthClient

  @unavailable :auth_unavailable

  @impl true
  def current_session(attrs), do: post("/internal/sessions/current", attrs)

  @impl true
  def lookup_user_by_phone(attrs), do: post("/internal/users/by_phone", attrs)

  @impl true
  def create_api_key(attrs), do: post("/internal/api_keys/create", attrs)

  @impl true
  def list_api_keys(attrs), do: post("/internal/api_keys/list", attrs)

  @impl true
  def revoke_api_key(attrs), do: post("/internal/api_keys/revoke", attrs)

  @impl true
  def verify_api_key(attrs), do: post("/internal/api_keys/verify", attrs)

  @impl true
  def mint_app_user_token(attrs), do: post("/internal/app_auth/token", attrs)

  @impl true
  def resolve_external_user(attrs), do: post("/internal/app_auth/resolve_user", attrs)

  @impl true
  def lookup_external_user(attrs), do: post("/internal/app_auth/lookup_user", attrs)

  @impl true
  def resolve_user_external_id(attrs), do: post("/internal/app_auth/resolve_user_external_id", attrs)

  @impl true
  def verify_app_user_token(attrs), do: post("/internal/app_auth/verify_token", attrs)

  @impl true
  def create_webhook_endpoint(attrs), do: post("/internal/webhooks/endpoints/create", attrs)

  @impl true
  def list_webhook_endpoints(attrs), do: post("/internal/webhooks/endpoints/list", attrs)

  @impl true
  def update_webhook_endpoint(attrs), do: post("/internal/webhooks/endpoints/update", attrs)

  @impl true
  def delete_webhook_endpoint(attrs), do: post("/internal/webhooks/endpoints/delete", attrs)

  @impl true
  def list_failed_webhooks(attrs), do: post("/internal/webhooks/outbox/failed", attrs)
  @impl true
  def list_webhook_deliveries(attrs), do: post("/internal/webhooks/outbox/deliveries", attrs)

  @impl true
  def app_usage(attrs), do: post("/internal/apps/usage", attrs)

  @impl true
  def app_usage_period(attrs), do: post("/internal/apps/usage_period", attrs)

  @impl true
  def reenqueue_webhook(attrs), do: post("/internal/webhooks/outbox/reenqueue", attrs)

  @impl true
  def reenqueue_webhooks_bulk(attrs), do: post("/internal/webhooks/outbox/reenqueue_bulk", attrs)

  @impl true
  def create_app(attrs), do: post("/internal/apps/create", attrs)

  @impl true
  def list_apps(attrs), do: post("/internal/apps/list", attrs)

  @impl true
  def admin_list_apps(attrs), do: post("/internal/apps/admin_list", attrs)

  @impl true
  def owns_app(attrs), do: post("/internal/apps/owns", attrs)

  @impl true
  def request_otp(attrs), do: post("/internal/otp/request", attrs)

  @impl true
  def verify_otp(attrs), do: post("/internal/otp/verify", attrs)

  @impl true
  def refresh(attrs), do: post("/internal/tokens/refresh", attrs)

  @impl true
  def revoke(attrs), do: post("/internal/tokens/revoke", attrs)

  @impl true
  def list_users(attrs), do: post("/internal/admin/users/list", attrs)

  @impl true
  def list_user_summaries(attrs), do: post("/internal/admin/users/summaries", attrs)

  @impl true
  def get_user_detail(attrs), do: post("/internal/admin/users/get", attrs)

  @impl true
  def suspend_user(attrs), do: post("/internal/admin/users/suspend", attrs)

  @impl true
  def reactivate_user(attrs), do: post("/internal/admin/users/reactivate", attrs)

  @impl true
  def ban_user(attrs), do: post("/internal/admin/users/ban", attrs)

  @impl true
  def set_user_role(attrs), do: post("/internal/admin/users/role", attrs)

  @impl true
  def delete_user(attrs), do: post("/internal/admin/users/delete", attrs)

  @impl true
  def list_reports(attrs), do: post("/internal/admin/reports/list", attrs)

  @impl true
  def update_report(attrs), do: post("/internal/admin/reports/update", attrs)

  @impl true
  def create_report(attrs), do: post("/internal/reports/create", attrs)

  @impl true
  def write_audit(attrs), do: post("/internal/admin/audit/write", attrs)

  @impl true
  def list_audit(attrs), do: post("/internal/admin/audit/list", attrs)

  @impl true
  def create_invite(attrs), do: post("/internal/invites/create", attrs)

  @impl true
  def get_user_phone(attrs), do: post("/internal/users/phone", attrs)

  @impl true
  def save_push_subscription(attrs), do: post("/internal/push/subscriptions/save", attrs)

  @impl true
  def delete_push_subscription(attrs), do: post("/internal/push/subscriptions/delete", attrs)

  @impl true
  def save_fcm_token(attrs), do: post("/internal/push/fcm-tokens/save", attrs)

  @impl true
  def delete_fcm_token(attrs), do: post("/internal/push/fcm-tokens/delete", attrs)

  @impl true
  def persistence_enabled? do
    # Bare boolean over the wire; on transport failure FAIL CLOSED (false = not trustworthy →
    # realtime socket rejects), never a truthy error tuple.
    case SharedInfra.HttpClient.get_result(
           base_url(),
           "/internal/sessions/persistence_enabled",
           unavailable: @unavailable
         ) do
      bool when is_boolean(bool) -> bool
      _ -> false
    end
  end

  defp post(path, attrs) do
    SharedInfra.HttpClient.post_result(base_url(), path, attrs, unavailable: @unavailable)
  end

  defp base_url do
    Application.get_env(:shared_infra, :auth_service_url) ||
      System.get_env("AUTH_SERVICE_URL") || "http://localhost:4101"
  end
end
