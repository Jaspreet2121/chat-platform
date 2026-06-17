defmodule ConversationService.Schemas.ConversationParticipant do
  @moduledoc """
  Ecto schema for the `conversation_participants` table.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  schema "conversation_participants" do
    field(:conversation_id, :binary_id, primary_key: true)
    field(:user_id, :binary_id, primary_key: true)
    field(:role, :string, default: "member")
    field(:joined_at, :utc_datetime_usec)
    field(:left_at, :utc_datetime_usec)
    field(:muted_until, :utc_datetime_usec)
  end

  def changeset(participant, attrs) do
    participant
    |> cast(attrs, [:conversation_id, :user_id, :role, :joined_at, :left_at, :muted_until])
    |> validate_required([:conversation_id, :user_id, :role])
    |> validate_inclusion(:role, ["member", "admin", "owner"])
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:user_id)
  end

  def remove_changeset(participant, attrs) do
    participant
    |> cast(attrs, [:left_at])
    |> validate_required([:left_at])
  end
end
