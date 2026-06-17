defmodule ConversationService.Schemas.Conversation do
  @moduledoc """
  Ecto schema for the `conversations` table.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "conversations" do
    field(:tenant_id, :binary_id)
    field(:type, :string)
    field(:title, :string)
    field(:avatar_media_id, :binary_id)
    field(:created_by, :binary_id)
    field(:status, :string, default: "active")
    field(:created_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [
      :id,
      :tenant_id,
      :type,
      :title,
      :avatar_media_id,
      :created_by,
      :status,
      :created_at,
      :updated_at
    ])
    |> validate_required([:type, :created_by, :status])
    |> validate_inclusion(:type, ["direct", "group", "business"])
    |> validate_inclusion(:status, ["active", "archived", "deleted"])
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:created_by)
  end

  def update_changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:title, :avatar_media_id, :status])
    |> validate_inclusion(:status, ["active", "archived", "deleted"])
  end
end
