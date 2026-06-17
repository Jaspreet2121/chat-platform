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

  def update_profile(%UserProfile{} = profile, attrs) do
    profile
    |> profile_update_changeset(attrs)
    |> Repo.update()
  end
end
