defmodule AuthService.AuthClientInProcess do
  @moduledoc """
  In-process adapter for `SharedInfra.AuthClient` — the default. Delegates straight to the
  existing `AuthService.*` functions, returning the SAME shapes, so routing edge apps through
  the client boundary is a zero-behavior-change refactor. A future HTTP adapter (separate
  auth-service container) will implement the same `SharedInfra.AuthClient` behaviour.
  """

  @behaviour SharedInfra.AuthClient

  alias AuthService.Accounts
  alias AuthService.ApiKeys
  alias AuthService.AppAuth
  alias AuthService.Webhooks
  alias AuthService.Moderation
  alias AuthService.OTP
  alias AuthService.Sessions
  alias AuthService.Tokens

  @impl true
  def current_session(attrs), do: Sessions.current_session(attrs)

  @impl true
  def lookup_user_by_phone(attrs),
    do: Accounts.lookup_active_by_phone(Map.get(attrs, "phone_number"))

  @impl true
  def create_api_key(attrs), do: ApiKeys.create_api_key(attrs)

  @impl true
  def list_api_keys(attrs), do: ApiKeys.list_api_keys(attrs)

  @impl true
  def revoke_api_key(attrs), do: ApiKeys.revoke_api_key(attrs)

  @impl true
  def verify_api_key(attrs), do: ApiKeys.verify_api_key(Map.get(attrs, "api_key"))

  @impl true
  def mint_app_user_token(attrs), do: AppAuth.mint_app_user_token(attrs)

  @impl true
  def resolve_external_user(attrs), do: AppAuth.resolve_external_user(attrs)

  @impl true
  def verify_app_user_token(attrs), do: AppAuth.verify_app_user_token(Map.get(attrs, "token"))

  @impl true
  def create_webhook_endpoint(attrs), do: Webhooks.create_endpoint(attrs)

  @impl true
  def list_webhook_endpoints(attrs), do: Webhooks.list_endpoints(attrs)

  @impl true
  def update_webhook_endpoint(attrs), do: Webhooks.update_endpoint(attrs)

  @impl true
  def delete_webhook_endpoint(attrs), do: Webhooks.delete_endpoint(attrs)

  @impl true
  def list_failed_webhooks(attrs), do: Webhooks.list_failed_deliveries(attrs)

  @impl true
  def reenqueue_webhook(attrs), do: Webhooks.reenqueue_delivery(attrs)

  @impl true
  def reenqueue_webhooks_bulk(attrs), do: Webhooks.reenqueue_deliveries_bulk(attrs)

  @impl true
  def create_app(attrs), do: AuthService.Apps.create_app(attrs)

  @impl true
  def list_apps(attrs), do: AuthService.Apps.list_apps(attrs)

  @impl true
  def owns_app(attrs), do: AuthService.Apps.owns_app(attrs)

  @impl true
  def persistence_enabled?, do: Sessions.persistence_enabled?()

  @impl true
  def request_otp(attrs), do: OTP.request_otp(attrs)

  @impl true
  def verify_otp(attrs), do: OTP.verify_otp(attrs)

  @impl true
  def refresh(attrs), do: Tokens.refresh(attrs)

  @impl true
  def revoke(attrs), do: Tokens.revoke(attrs)

  @impl true
  def list_users(attrs), do: {:ok, Accounts.list_users(attrs)}

  @impl true
  def get_user_detail(attrs), do: Moderation.user_detail(attrs)

  @impl true
  def suspend_user(attrs), do: Moderation.suspend_user(attrs)

  @impl true
  def reactivate_user(attrs), do: Moderation.reactivate_user(attrs)

  @impl true
  def ban_user(attrs), do: Moderation.ban_user(attrs)

  @impl true
  def set_user_role(attrs), do: Moderation.set_role(attrs)

  @impl true
  def delete_user(attrs), do: Moderation.delete_user(attrs)

  @impl true
  def list_reports(attrs), do: Moderation.list_reports(attrs)

  @impl true
  def update_report(attrs), do: Moderation.update_report(attrs)

  @impl true
  def write_audit(attrs), do: Moderation.write_audit(attrs)

  @impl true
  def list_audit(attrs), do: Moderation.list_audit(attrs)
end
