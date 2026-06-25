defmodule MessageService.Schemas.MessageReaction do
  @moduledoc """
  Ecto schema for the Postgres-backed `message_reactions` table.

  WhatsApp model: ONE reaction per user per message (PK `(message_id, user_id)`), changeable — setting
  a new emoji replaces the user's previous one via an upsert on the composite key.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  schema "message_reactions" do
    field(:conversation_id, :binary_id)
    field(:message_id, :binary_id, primary_key: true)
    field(:user_id, :binary_id, primary_key: true)
    field(:emoji, :string)
    field(:created_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  def changeset(reaction, attrs) do
    reaction
    |> cast(attrs, [:conversation_id, :message_id, :user_id, :emoji, :created_at, :updated_at])
    |> validate_required([:conversation_id, :message_id, :user_id, :emoji])
  end
end
