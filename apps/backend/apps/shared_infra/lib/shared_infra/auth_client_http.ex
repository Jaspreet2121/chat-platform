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
  def request_otp(attrs), do: post("/internal/otp/request", attrs)

  @impl true
  def verify_otp(attrs), do: post("/internal/otp/verify", attrs)

  @impl true
  def refresh(attrs), do: post("/internal/tokens/refresh", attrs)

  @impl true
  def revoke(attrs), do: post("/internal/tokens/revoke", attrs)

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
