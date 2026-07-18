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

  def get_current_profile(attrs), do: adapter().get_current_profile(attrs)
  def get_public_profile(attrs), do: adapter().get_public_profile(attrs)
  def update_current_profile(attrs), do: adapter().update_current_profile(attrs)

  @doc "A user's last_seen_visibility (everyone|contacts|nobody) for presence gating. %{last_seen_visibility: v}."
  def last_seen_visibility(attrs), do: adapter().last_seen_visibility(attrs)

  @doc "The configured User client adapter (default `UserService.UserClientInProcess`)."
  def adapter do
    Application.get_env(:shared_infra, :user_client_adapter, UserService.UserClientInProcess)
  end
end
