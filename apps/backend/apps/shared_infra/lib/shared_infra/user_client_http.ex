defmodule SharedInfra.UserClientHttp do
  @moduledoc """
  HTTP adapter for `SharedInfra.UserClient` — calls user-service's internal HTTP API
  (`UserService.HTTP.Router`) over the network. Selected by `USER_CLIENT_ADAPTER=http`; default stays
  `UserService.UserClientInProcess` (zero behavior change until flipped).

  Same template as `SharedInfra.AuthClientHttp`: lives in shared_infra (not user_service); profile
  responses (atom-keyed `user_id/display_name/avatar_media_id/bio`) round-trip via
  `SharedInfra.InternalApi.decode_result/1` through `SharedInfra.HttpClient`. Transport failure →
  `{:error, :user_unavailable}` (gateway → 503). Base URL from `USER_SERVICE_URL`.
  """

  @behaviour SharedInfra.UserClient

  @unavailable :user_unavailable

  @impl true
  def get_current_profile(attrs), do: post("/internal/profiles/current", attrs)

  @impl true
  def get_public_profile(attrs), do: post("/internal/profiles/public", attrs)

  @impl true
  def update_current_profile(attrs), do: post("/internal/profiles/update", attrs)

  @impl true
  def last_seen_visibility(attrs), do: post("/internal/privacy/last_seen_visibility", attrs)

  defp post(path, attrs) do
    SharedInfra.HttpClient.post_result(base_url(), path, attrs, unavailable: @unavailable)
  end

  defp base_url do
    Application.get_env(:shared_infra, :user_service_url) ||
      System.get_env("USER_SERVICE_URL") || "http://localhost:4103"
  end
end
