defmodule ConversationService.Schemas.ConversationSettings do
  @moduledoc """
  Ecto schema for the `conversation_settings` table.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:conversation_id, :binary_id, autogenerate: false}

  schema "conversation_settings" do
    field(:only_admins_can_send, :boolean, default: false)
    field(:only_admins_can_add_members, :boolean, default: false)
    field(:message_retention_days, :integer)
    field(:created_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [
      :conversation_id,
      :only_admins_can_send,
      :only_admins_can_add_members,
      :message_retention_days
    ])
    |> validate_required([:conversation_id, :only_admins_can_send, :only_admins_can_add_members])
    |> validate_number(:message_retention_days, greater_than: 0)
    |> foreign_key_constraint(:conversation_id)
  end

  def update_changeset(settings, attrs) do
    settings
    |> cast(attrs, [:only_admins_can_send, :only_admins_can_add_members, :message_retention_days])
    |> validate_required([:only_admins_can_send, :only_admins_can_add_members])
    |> validate_number(:message_retention_days, greater_than: 0)
  end
end
