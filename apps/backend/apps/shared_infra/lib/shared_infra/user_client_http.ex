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
  def regenerate_upi_qr(attrs), do: post("/internal/profiles/regenerate_upi_qr", attrs)

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
  def publish_nearby(attrs), do: post("/internal/nearby/publish", attrs)

  @impl true
  def stop_nearby(attrs), do: post("/internal/nearby/stop", attrs)

  @impl true
  def send_nearby_request(attrs), do: post("/internal/nearby/requests/create", attrs)

  @impl true
  def list_nearby_requests(attrs), do: post("/internal/nearby/requests/list", attrs)

  @impl true
  def respond_nearby_request(attrs), do: post("/internal/nearby/requests/respond", attrs)

  @impl true
  def get_nearby_settings(attrs), do: post("/internal/nearby/settings/get", attrs)

  @impl true
  def update_nearby_settings(attrs), do: post("/internal/nearby/settings/update", attrs)

  @impl true
  def admit_ble_targets(attrs), do: post("/internal/nearby/ble/admit", attrs)

  @impl true
  def get_dating_profile(attrs), do: post("/internal/dating/profile/get", attrs)

  @impl true
  def update_dating_profile(attrs), do: post("/internal/dating/profile/update", attrs)

  @impl true
  def dating_deck(attrs), do: post("/internal/dating/deck", attrs)

  @impl true
  def dating_swipe(attrs), do: post("/internal/dating/swipe", attrs)

  @impl true
  def dating_likes(attrs), do: post("/internal/dating/likes", attrs)

  @impl true
  def dating_matches(attrs), do: post("/internal/dating/matches", attrs)

  @impl true
  def dating_unmatch(attrs), do: post("/internal/dating/unmatch", attrs)

  @impl true
  def dating_unmatch_pair(attrs), do: post("/internal/dating/unmatch_pair", attrs)

  @impl true
  def dating_attach_conversation(attrs), do: post("/internal/dating/attach_conversation", attrs)

  @impl true
  def get_auto_replies(attrs), do: post("/internal/auto_replies/get", attrs)

  @impl true
  def update_auto_replies(attrs), do: post("/internal/auto_replies/update", attrs)

  @impl true
  def claim_auto_reply(attrs), do: post("/internal/auto_replies/claim", attrs)

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
