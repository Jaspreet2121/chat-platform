defmodule ConversationService.Schemas.GroupProfile do
  @moduledoc """
  Ecto schema for the `group_profiles` table.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:conversation_id, :binary_id, autogenerate: false}

  schema "group_profiles" do
    field(:name, :string)
    field(:description, :string)
    field(:avatar_media_id, :binary_id)
    field(:avatar_object_key, :string)
    field(:created_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  def changeset(group_profile, attrs) do
    group_profile
    |> cast(attrs, [:conversation_id, :name, :description, :avatar_media_id, :avatar_object_key])
    |> validate_required([:conversation_id, :name])
    |> foreign_key_constraint(:conversation_id)
  end

  def update_changeset(group_profile, attrs) do
    group_profile
    |> cast(attrs, [:name, :description, :avatar_media_id, :avatar_object_key])
    |> validate_required([:name])
  end
end
