defmodule ConversationService.ConversationSettingsStore do
  @moduledoc """
  Data-access boundary for conversation settings persistence.
  """

  alias ConversationService.Repo
  alias ConversationService.Schemas.ConversationSettings

  def settings_changeset(attrs \\ %{}) do
    ConversationSettings.changeset(%ConversationSettings{}, attrs)
  end

  def settings_update_changeset(%ConversationSettings{} = settings, attrs) do
    ConversationSettings.update_changeset(settings, attrs)
  end

  def create_settings(attrs) do
    attrs
    |> settings_changeset()
    |> Repo.insert()
  end

  def get_settings(conversation_id), do: Repo.get(ConversationSettings, conversation_id)

  def update_settings(%ConversationSettings{} = settings, attrs) do
    settings
    |> settings_update_changeset(attrs)
    |> Repo.update()
  end
end
