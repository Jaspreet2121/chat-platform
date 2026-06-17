defmodule ConversationService.GroupProfileStore do
  @moduledoc """
  Data-access boundary for group profile persistence.
  """

  alias ConversationService.Repo
  alias ConversationService.Schemas.GroupProfile

  def group_profile_changeset(attrs \\ %{}) do
    GroupProfile.changeset(%GroupProfile{}, attrs)
  end

  def group_profile_update_changeset(%GroupProfile{} = group_profile, attrs) do
    GroupProfile.update_changeset(group_profile, attrs)
  end

  def create_group_profile(attrs) do
    attrs
    |> group_profile_changeset()
    |> Repo.insert()
  end

  def get_group_profile(conversation_id), do: Repo.get(GroupProfile, conversation_id)

  def update_group_profile(%GroupProfile{} = group_profile, attrs) do
    group_profile
    |> group_profile_update_changeset(attrs)
    |> Repo.update()
  end
end
