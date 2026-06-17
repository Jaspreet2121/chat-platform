defmodule UserService.SettingsStore do
  @moduledoc """
  Data-access boundary for user settings persistence.
  """

  alias UserService.Repo
  alias UserService.Schemas.UserSettings

  def settings_changeset(attrs \\ %{}) do
    UserSettings.changeset(%UserSettings{}, attrs)
  end

  def settings_update_changeset(%UserSettings{} = settings, attrs) do
    UserSettings.update_changeset(settings, attrs)
  end

  def create_settings(attrs) do
    attrs
    |> settings_changeset()
    |> Repo.insert()
  end

  def get_settings(user_id), do: Repo.get(UserSettings, user_id)

  def update_settings(%UserSettings{} = settings, attrs) do
    settings
    |> settings_update_changeset(attrs)
    |> Repo.update()
  end
end
