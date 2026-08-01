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
  @callback check_username(attrs()) :: result()

  # Optional so a partial test stub of this behaviour doesn't need to implement everything; the real adapters do.
  @optional_callbacks get_privacy: 1, update_privacy: 1, lookup_by_username: 1, check_username: 1

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
  def check_username(attrs), do: adapter().check_username(attrs)

  @doc "The configured User client adapter (default `UserService.UserClientInProcess`)."
  def adapter do
    Application.get_env(:shared_infra, :user_client_adapter, UserService.UserClientInProcess)
  end
end
