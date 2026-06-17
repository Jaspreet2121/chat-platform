defmodule UserService.PrivacyStore do
  @moduledoc """
  Data-access boundary for user privacy settings persistence.
  """

  alias UserService.Repo
  alias UserService.Schemas.UserPrivacySettings

  def privacy_changeset(attrs \\ %{}) do
    UserPrivacySettings.changeset(%UserPrivacySettings{}, attrs)
  end

  def privacy_update_changeset(%UserPrivacySettings{} = privacy_settings, attrs) do
    UserPrivacySettings.update_changeset(privacy_settings, attrs)
  end

  def create_privacy_settings(attrs) do
    attrs
    |> privacy_changeset()
    |> Repo.insert()
  end

  def get_privacy_settings(user_id), do: Repo.get(UserPrivacySettings, user_id)

  def update_privacy_settings(%UserPrivacySettings{} = privacy_settings, attrs) do
    privacy_settings
    |> privacy_update_changeset(attrs)
    |> Repo.update()
  end
end
