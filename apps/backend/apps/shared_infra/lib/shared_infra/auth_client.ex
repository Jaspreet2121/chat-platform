defmodule SharedInfra.AuthClient do
  @moduledoc """
  Client boundary for the Auth service — the seam that lets edge apps (api_gateway,
  realtime_gateway) stop calling `AuthService.*` in-process directly.

  Mirrors `SharedInfra.Kafka.Producer` / `SharedInfra.Scylla.Client`: this module is a
  behaviour AND a configured dispatcher. The adapter is selected from
  `:shared_infra, :auth_client_adapter` (set in config to `AuthService.AuthClientInProcess`
  by default). The default adapter delegates IN-PROCESS to `AuthService.*`, so behavior is
  byte-for-byte identical today. A future `AUTH_CLIENT_ADAPTER=http` selects an HTTP adapter
  (calling a separate auth-service container) WITHOUT touching the call sites — that is the
  point of this boundary. (The HTTP adapter is a later sub-slice; only the in-process adapter
  ships now.)

  shared_infra intentionally does NOT compile-depend on auth_service: the adapter module is
  resolved from config at runtime, so the base lib stays free of a service dependency.
  """

  @type attrs :: map()
  @type result :: {:ok, map()} | {:error, term()}

  @callback current_session(attrs()) :: result()
  @callback persistence_enabled?() :: boolean()
  @callback lookup_user_by_phone(attrs()) :: result()
  @callback request_otp(attrs()) :: result()
  @callback verify_otp(attrs()) :: result()
  @callback refresh(attrs()) :: result()
  @callback revoke(attrs()) :: result()
  @callback list_users(attrs()) :: result()
  @callback list_user_summaries(attrs()) :: result()
  @callback get_user_detail(attrs()) :: result()
  @callback suspend_user(attrs()) :: result()
  @callback reactivate_user(attrs()) :: result()
  @callback ban_user(attrs()) :: result()
  @callback set_user_role(attrs()) :: result()
  @callback delete_user(attrs()) :: result()
  @callback list_reports(attrs()) :: result()
  @callback update_report(attrs()) :: result()
  @callback write_audit(attrs()) :: result()
  @callback list_audit(attrs()) :: result()

  @callback create_invite(attrs()) :: result()
  @callback get_user_phone(attrs()) :: result()
  @callback save_push_subscription(attrs()) :: result()
  @callback delete_push_subscription(attrs()) :: result()

  @callback create_api_key(attrs()) :: result()
  @callback list_api_keys(attrs()) :: result()
  @callback revoke_api_key(attrs()) :: result()
  @callback verify_api_key(attrs()) :: result()
  @callback mint_app_user_token(attrs()) :: result()
  @callback resolve_external_user(attrs()) :: result()
  @callback lookup_external_user(attrs()) :: result()
  @callback resolve_user_external_id(attrs()) :: result()
  @callback verify_app_user_token(attrs()) :: result()
  @callback create_webhook_endpoint(attrs()) :: result()
  @callback list_webhook_endpoints(attrs()) :: result()
  @callback update_webhook_endpoint(attrs()) :: result()
  @callback delete_webhook_endpoint(attrs()) :: result()
  @callback list_failed_webhooks(attrs()) :: result()
  @callback list_webhook_deliveries(attrs()) :: result()
  @callback app_usage(attrs()) :: result()
  @callback reenqueue_webhook(attrs()) :: result()
  @callback reenqueue_webhooks_bulk(attrs()) :: result()
  @callback create_app(attrs()) :: result()
  @callback list_apps(attrs()) :: result()
  @callback owns_app(attrs()) :: result()

  # Optional so the many test stubs that implement this behaviour don't all need to add them; the real
  # adapters (in-process + HTTP) both implement them, which is all the dispatcher ever resolves to.
  @optional_callbacks set_user_role: 1,
                      delete_user: 1,
                      lookup_user_by_phone: 1,
                      create_api_key: 1,
                      list_api_keys: 1,
                      revoke_api_key: 1,
                      verify_api_key: 1,
                      mint_app_user_token: 1,
                      resolve_external_user: 1,
                      lookup_external_user: 1,
                      verify_app_user_token: 1,
                      create_webhook_endpoint: 1,
                      list_webhook_endpoints: 1,
                      update_webhook_endpoint: 1,
                      delete_webhook_endpoint: 1,
                      list_failed_webhooks: 1,
                      list_webhook_deliveries: 1,
                      app_usage: 1,
                      reenqueue_webhook: 1,
                      reenqueue_webhooks_bulk: 1,
                      create_app: 1,
                      list_apps: 1,
                      owns_app: 1

  def current_session(attrs), do: adapter().current_session(attrs)
  def persistence_enabled?, do: adapter().persistence_enabled?()
  def lookup_user_by_phone(attrs), do: adapter().lookup_user_by_phone(attrs)
  def create_api_key(attrs), do: adapter().create_api_key(attrs)
  def list_api_keys(attrs), do: adapter().list_api_keys(attrs)
  def revoke_api_key(attrs), do: adapter().revoke_api_key(attrs)
  def verify_api_key(attrs), do: adapter().verify_api_key(attrs)
  def mint_app_user_token(attrs), do: adapter().mint_app_user_token(attrs)
  def resolve_external_user(attrs), do: adapter().resolve_external_user(attrs)

  @doc "Resolve-ONLY external-id lookup (never creates) — for read/reference contexts. :user_not_found on miss."
  def lookup_external_user(attrs), do: adapter().lookup_external_user(attrs)
  def resolve_user_external_id(attrs), do: adapter().resolve_user_external_id(attrs)
  def verify_app_user_token(attrs), do: adapter().verify_app_user_token(attrs)
  def create_webhook_endpoint(attrs), do: adapter().create_webhook_endpoint(attrs)
  def list_webhook_endpoints(attrs), do: adapter().list_webhook_endpoints(attrs)
  def update_webhook_endpoint(attrs), do: adapter().update_webhook_endpoint(attrs)
  def delete_webhook_endpoint(attrs), do: adapter().delete_webhook_endpoint(attrs)
  def list_failed_webhooks(attrs), do: adapter().list_failed_webhooks(attrs)

  @doc "Owner-facing webhook delivery log for ONE owned app (every status). app_id mandatory."
  def list_webhook_deliveries(attrs), do: adapter().list_webhook_deliveries(attrs)

  @doc "Owner-facing entity counts for ONE owned app: users/conversations/messages/storage_bytes."
  def app_usage(attrs), do: adapter().app_usage(attrs)
  def reenqueue_webhook(attrs), do: adapter().reenqueue_webhook(attrs)
  def reenqueue_webhooks_bulk(attrs), do: adapter().reenqueue_webhooks_bulk(attrs)
  def create_app(attrs), do: adapter().create_app(attrs)
  def list_apps(attrs), do: adapter().list_apps(attrs)
  def owns_app(attrs), do: adapter().owns_app(attrs)
  def request_otp(attrs), do: adapter().request_otp(attrs)
  def verify_otp(attrs), do: adapter().verify_otp(attrs)
  def refresh(attrs), do: adapter().refresh(attrs)
  def revoke(attrs), do: adapter().revoke(attrs)
  def list_users(attrs), do: adapter().list_users(attrs)
  def list_user_summaries(attrs), do: adapter().list_user_summaries(attrs)
  def get_user_detail(attrs), do: adapter().get_user_detail(attrs)
  def suspend_user(attrs), do: adapter().suspend_user(attrs)
  def reactivate_user(attrs), do: adapter().reactivate_user(attrs)
  def ban_user(attrs), do: adapter().ban_user(attrs)
  def set_user_role(attrs), do: adapter().set_user_role(attrs)
  def delete_user(attrs), do: adapter().delete_user(attrs)
  def list_reports(attrs), do: adapter().list_reports(attrs)
  def update_report(attrs), do: adapter().update_report(attrs)
  def write_audit(attrs), do: adapter().write_audit(attrs)
  def list_audit(attrs), do: adapter().list_audit(attrs)

  def create_invite(attrs), do: adapter().create_invite(attrs)
  def get_user_phone(attrs), do: adapter().get_user_phone(attrs)
  def save_push_subscription(attrs), do: adapter().save_push_subscription(attrs)
  def delete_push_subscription(attrs), do: adapter().delete_push_subscription(attrs)

  @doc "The configured Auth client adapter (default `AuthService.AuthClientInProcess`)."
  def adapter do
    Application.get_env(:shared_infra, :auth_client_adapter, AuthService.AuthClientInProcess)
  end
end
