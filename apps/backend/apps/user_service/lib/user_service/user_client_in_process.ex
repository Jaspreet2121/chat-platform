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
end
