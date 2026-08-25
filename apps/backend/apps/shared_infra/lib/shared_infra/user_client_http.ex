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
  def lookup_by_username(attrs), do: post("/internal/usernames/lookup", attrs)

  @impl true
  def search_users(attrs), do: post("/internal/users/search", attrs)

  @impl true
  def list_quick_replies(attrs), do: post("/internal/quick_replies/list", attrs)

  @impl true
  def create_quick_reply(attrs), do: post("/internal/quick_replies/create", attrs)

  @impl true
  def update_quick_reply(attrs), do: post("/internal/quick_replies/update", attrs)

  @impl true
  def delete_quick_reply(attrs), do: post("/internal/quick_replies/delete", attrs)

  @impl true
  def reorder_quick_replies(attrs), do: post("/internal/quick_replies/reorder", attrs)

  @impl true
  def check_username(attrs), do: post("/internal/usernames/check", attrs)

  @impl true
  def last_seen_visibility(attrs), do: post("/internal/privacy/last_seen_visibility", attrs)

  @impl true
  def get_privacy(attrs), do: post("/internal/privacy/get", attrs)

  @impl true
  def update_privacy(attrs), do: post("/internal/privacy/update", attrs)

  @impl true
  def discover_nearby(attrs), do: post("/internal/nearby/discover", attrs)

  @impl true
  def stop_nearby(attrs), do: post("/internal/nearby/stop", attrs)

  @impl true
  def send_nearby_request(attrs), do: post("/internal/nearby/requests/create", attrs)

  @impl true
  def list_nearby_requests(attrs), do: post("/internal/nearby/requests/list", attrs)

  @impl true
  def respond_nearby_request(attrs), do: post("/internal/nearby/requests/respond", attrs)

  defp post(path, attrs) do
    SharedInfra.HttpClient.post_result(base_url(), path, attrs, unavailable: @unavailable)
  end

  defp base_url do
    Application.get_env(:shared_infra, :user_service_url) ||
      System.get_env("USER_SERVICE_URL") || "http://localhost:4103"
  end

  @impl true
  def list_favourites(attrs), do: post("/internal/favourites/list", attrs)

  @impl true
  def add_favourite(attrs), do: post("/internal/favourites/add", attrs)

  @impl true
  def remove_favourite(attrs), do: post("/internal/favourites/remove", attrs)

  @impl true
  def reorder_favourites(attrs), do: post("/internal/favourites/reorder", attrs)
end
