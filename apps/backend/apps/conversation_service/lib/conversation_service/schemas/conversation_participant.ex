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
    # WHY the row is left (078): 'removed' = moderation removal; 'left' = voluntary leave. NULL while
    # active. The invite-link rejoin rule keys off this — removed users are refused, leavers reactivate.
    field(:left_reason, :string)
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
    |> cast(attrs, [:left_at, :left_reason])
    |> validate_required([:left_at, :left_reason])
    |> validate_inclusion(:left_reason, ["left", "removed"])
  end

  # Reactivation (a voluntary leaver rejoining via invite link, or the owner re-adding a left row):
  # clears left_at/left_reason and resets role + joined_at — membership restarts, roles aren't retained.
  def reactivate_changeset(participant, attrs) do
    participant
    |> cast(attrs, [:role, :joined_at])
    |> validate_required([:role, :joined_at])
    |> validate_inclusion(:role, ["member", "admin", "owner"])
    |> put_change(:left_at, nil)
    |> put_change(:left_reason, nil)
  end
end
