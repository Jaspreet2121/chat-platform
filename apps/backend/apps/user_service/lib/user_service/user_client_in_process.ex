defmodule UserService.UserClientInProcess do
  @moduledoc """
  In-process adapter for `SharedInfra.UserClient` — the default. Delegates straight to the
  existing `UserService.Profiles` functions, returning the SAME shapes, so routing edge apps
  through the client boundary is a zero-behavior-change refactor. A future HTTP adapter
  (separate user-service container) implements the same behaviour.
  """

  @behaviour SharedInfra.UserClient

  alias UserService.Profiles

  @impl true
  def get_current_profile(attrs), do: Profiles.get_current_profile(attrs)

  @impl true
  def get_public_profile(attrs), do: Profiles.get_public_profile(attrs)

  @impl true
  def update_current_profile(attrs), do: Profiles.update_current_profile(attrs)

  @impl true
  def last_seen_visibility(attrs), do: UserService.Privacy.last_seen_visibility(attrs)

  @impl true
  def get_privacy(attrs), do: UserService.Privacy.get_privacy(attrs)

  @impl true
  def lookup_by_username(attrs), do: UserService.Usernames.lookup(attrs)
  @impl true
  def search_users(attrs), do: Profiles.search_users(attrs)

  @impl true
  def list_quick_replies(attrs), do: UserService.QuickReplies.list(attrs)

  @impl true
  def create_quick_reply(attrs), do: UserService.QuickReplies.create(attrs)

  @impl true
  def update_quick_reply(attrs), do: UserService.QuickReplies.update(attrs)

  @impl true
  def delete_quick_reply(attrs), do: UserService.QuickReplies.delete(attrs)

  @impl true
  def reorder_quick_replies(attrs), do: UserService.QuickReplies.reorder(attrs)

  @impl true
  def check_username(attrs), do: UserService.Usernames.check_availability(attrs)

  @impl true
  def update_privacy(attrs), do: UserService.Privacy.update_privacy(attrs)

  @impl true
  def list_favourites(attrs), do: UserService.FavouriteContacts.list(attrs)

  @impl true
  def add_favourite(attrs), do: UserService.FavouriteContacts.add(attrs)

  @impl true
  def remove_favourite(attrs), do: UserService.FavouriteContacts.remove(attrs)

  @impl true
  def reorder_favourites(attrs), do: UserService.FavouriteContacts.reorder(attrs)
end
