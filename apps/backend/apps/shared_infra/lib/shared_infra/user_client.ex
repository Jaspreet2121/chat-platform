defmodule SharedInfra.UserClient do
  @moduledoc """
  Client boundary for the User service — lets edge apps stop calling `UserService.*`
  in-process directly.

  Same pattern as `SharedInfra.AuthClient` / `SharedInfra.ConversationClient`: behaviour AND
  configured dispatcher. Adapter from `:shared_infra, :user_client_adapter` (config default
  `UserService.UserClientInProcess`, delegates in-process → zero behavior change). A future
  `USER_CLIENT_ADAPTER=http` selects an HTTP adapter (separate user-service container) WITHOUT
  touching call sites. shared_infra resolves the adapter from config at runtime, so it stays
  free of a service dependency.
  """

  @type attrs :: map()
  @type result :: {:ok, map()} | {:error, term()}

  @callback get_current_profile(attrs()) :: result()
  @callback get_public_profile(attrs()) :: result()
  @callback update_current_profile(attrs()) :: result()
  @callback last_seen_visibility(attrs()) :: result()
  # Full privacy settings read + sparse update (the first-party GET/PATCH /api/v1/privacy surface + enforcement).
  @callback get_privacy(attrs()) :: result()
  @callback update_privacy(attrs()) :: result()
  # Usernames (080): app-scoped handle → user_id resolution + the availability probe.
  # FAVOURITE CONTACTS (090) — the Calls tab's favourites, owner-scoped per-user state.
  @callback list_favourites(attrs()) :: result()
  @callback add_favourite(attrs()) :: result()
  @callback remove_favourite(attrs()) :: result()
  @callback reorder_favourites(attrs()) :: result()
  @callback lookup_by_username(attrs()) :: result()
  @callback search_users(attrs()) :: result()
  @callback list_quick_replies(attrs()) :: result()
  @callback create_quick_reply(attrs()) :: result()
  @callback update_quick_reply(attrs()) :: result()
  @callback delete_quick_reply(attrs()) :: result()
  @callback reorder_quick_replies(attrs()) :: result()
  @callback check_username(attrs()) :: result()
  # Nearby People (101): short-lived discovery and consent-based connection requests.
  @callback discover_nearby(attrs()) :: result()
  @callback stop_nearby(attrs()) :: result()
  @callback send_nearby_request(attrs()) :: result()
  @callback list_nearby_requests(attrs()) :: result()
  @callback respond_nearby_request(attrs()) :: result()
  # Auto-replies (102): settings + the engine's at-least-once claim.
  @callback get_auto_replies(attrs()) :: result()
  @callback update_auto_replies(attrs()) :: result()
  @callback claim_auto_reply(attrs()) :: result()

  # Optional so a partial test stub of this behaviour doesn't need to implement everything; the real adapters do.
  @optional_callbacks get_privacy: 1,
                      update_privacy: 1,
                      lookup_by_username: 1,
                      check_username: 1,
                      search_users: 1,
                      list_quick_replies: 1,
                      create_quick_reply: 1,
                      update_quick_reply: 1,
                      delete_quick_reply: 1,
                      reorder_quick_replies: 1,
                      discover_nearby: 1,
                      stop_nearby: 1,
                      send_nearby_request: 1,
                      list_nearby_requests: 1,
                      respond_nearby_request: 1,
                      get_auto_replies: 1,
                      update_auto_replies: 1,
                      claim_auto_reply: 1

  def get_current_profile(attrs), do: adapter().get_current_profile(attrs)
  def list_favourites(attrs), do: adapter().list_favourites(attrs)
  def add_favourite(attrs), do: adapter().add_favourite(attrs)
  def remove_favourite(attrs), do: adapter().remove_favourite(attrs)
  def reorder_favourites(attrs), do: adapter().reorder_favourites(attrs)
  def get_public_profile(attrs), do: adapter().get_public_profile(attrs)
  def update_current_profile(attrs), do: adapter().update_current_profile(attrs)

  @doc "A user's last_seen_visibility (everyone|contacts|nobody) for presence gating. %{last_seen_visibility: v}."
  def last_seen_visibility(attrs), do: adapter().last_seen_visibility(attrs)

  @doc "A user's full privacy settings: %{last_seen_visibility, profile_photo_visibility, read_receipts_enabled}."
  def get_privacy(attrs), do: adapter().get_privacy(attrs)

  @doc "Sparse update of a user's privacy settings; returns the full updated map or a validation error."
  def update_privacy(attrs), do: adapter().update_privacy(attrs)
  def lookup_by_username(attrs), do: adapter().lookup_by_username(attrs)
  def search_users(attrs), do: adapter().search_users(attrs)
  def list_quick_replies(attrs), do: adapter().list_quick_replies(attrs)
  def create_quick_reply(attrs), do: adapter().create_quick_reply(attrs)
  def update_quick_reply(attrs), do: adapter().update_quick_reply(attrs)
  def delete_quick_reply(attrs), do: adapter().delete_quick_reply(attrs)
  def reorder_quick_replies(attrs), do: adapter().reorder_quick_replies(attrs)
  def check_username(attrs), do: adapter().check_username(attrs)
  def discover_nearby(attrs), do: adapter().discover_nearby(attrs)
  def stop_nearby(attrs), do: adapter().stop_nearby(attrs)
  def send_nearby_request(attrs), do: adapter().send_nearby_request(attrs)
  def list_nearby_requests(attrs), do: adapter().list_nearby_requests(attrs)
  def respond_nearby_request(attrs), do: adapter().respond_nearby_request(attrs)
  def get_auto_replies(attrs), do: adapter().get_auto_replies(attrs)
  def update_auto_replies(attrs), do: adapter().update_auto_replies(attrs)
  def claim_auto_reply(attrs), do: adapter().claim_auto_reply(attrs)

  @doc "The configured User client adapter (default `UserService.UserClientInProcess`)."
  def adapter do
    Application.get_env(:shared_infra, :user_client_adapter, UserService.UserClientInProcess)
  end
end
