defmodule AuthService.AuthClientInProcess do
  @moduledoc """
  In-process adapter for `SharedInfra.AuthClient` — the default. Delegates straight to the
  existing `AuthService.*` functions, returning the SAME shapes, so routing edge apps through
  the client boundary is a zero-behavior-change refactor. A future HTTP adapter (separate
  auth-service container) will implement the same `SharedInfra.AuthClient` behaviour.
  """

  @behaviour SharedInfra.AuthClient

  alias AuthService.Accounts
  alias AuthService.Moderation
  alias AuthService.OTP
  alias AuthService.Sessions
  alias AuthService.Tokens

  @impl true
  def current_session(attrs), do: Sessions.current_session(attrs)

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
  def suspend_user(attrs), do: Moderation.suspend_user(attrs)

  @impl true
  def reactivate_user(attrs), do: Moderation.reactivate_user(attrs)

  @impl true
  def ban_user(attrs), do: Moderation.ban_user(attrs)

  @impl true
  def list_reports(attrs), do: Moderation.list_reports(attrs)

  @impl true
  def update_report(attrs), do: Moderation.update_report(attrs)

  @impl true
  def write_audit(attrs), do: Moderation.write_audit(attrs)

  @impl true
  def list_audit(attrs), do: Moderation.list_audit(attrs)
end
