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
  @callback request_otp(attrs()) :: result()
  @callback verify_otp(attrs()) :: result()
  @callback refresh(attrs()) :: result()
  @callback revoke(attrs()) :: result()

  def current_session(attrs), do: adapter().current_session(attrs)
  def persistence_enabled?, do: adapter().persistence_enabled?()
  def request_otp(attrs), do: adapter().request_otp(attrs)
  def verify_otp(attrs), do: adapter().verify_otp(attrs)
  def refresh(attrs), do: adapter().refresh(attrs)
  def revoke(attrs), do: adapter().revoke(attrs)

  @doc "The configured Auth client adapter (default `AuthService.AuthClientInProcess`)."
  def adapter do
    Application.get_env(:shared_infra, :auth_client_adapter, AuthService.AuthClientInProcess)
  end
end
