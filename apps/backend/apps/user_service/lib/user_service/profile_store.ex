defmodule UserService.ProfileStore do
  @moduledoc """
  Data-access boundary for user profile persistence.
  """

  alias UserService.Repo
  alias UserService.Schemas.UserProfile

  def profile_changeset(attrs \\ %{}) do
    UserProfile.changeset(%UserProfile{}, attrs)
  end

  def profile_update_changeset(%UserProfile{} = profile, attrs) do
    UserProfile.update_changeset(profile, attrs)
  end

  def create_profile(attrs) do
    attrs
    |> profile_changeset()
    |> Repo.insert()
  end

  def get_profile(user_id), do: Repo.get(UserProfile, user_id)

  @doc """
  Tenant-scoped profile read: the row for `user_id` ONLY if it belongs to `app_id`. A cross-tenant
  user_id → nil (the caller can't read another app's profile). Used by the public-profile + avatar reads.
  """
  def get_profile_in_app(user_id, app_id) do
    Repo.get_by(UserProfile, user_id: user_id, app_id: app_id)
  end

  def update_profile(%UserProfile{} = profile, attrs) do
    profile
    |> profile_update_changeset(attrs)
    |> Repo.update()
  end
end
