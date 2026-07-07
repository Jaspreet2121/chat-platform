defmodule ConversationService.Schemas.CallParticipant do
  @moduledoc """
  Ecto schema for the `group_call_participants` table (Phase-3 group calling). One row per (call, user) —
  a member invited to / joined in a GROUP call and their per-member state. Direct 1-on-1 calls have no rows
  here. Composite primary key (call_id + user_id): a user appears once per call.

  Table is `group_call_participants` (NOT `call_participants`) to avoid colliding with the LEGACY
  `call_participants` table from migration 010 (the abandoned native-WebRTC design).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @statuses ~w(invited joined declined left missed)

  schema "group_call_participants" do
    field(:call_id, :binary_id, primary_key: true)
    field(:user_id, :binary_id, primary_key: true)
    field(:status, :string, default: "invited")
    field(:joined_at, :utc_datetime_usec)
    field(:left_at, :utc_datetime_usec)
    field(:created_at, :utc_datetime_usec)
  end

  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:call_id, :user_id, :status, :joined_at, :left_at, :created_at])
    |> validate_required([:call_id, :user_id, :status, :created_at])
    |> validate_inclusion(:status, @statuses)
  end

  # Per-member transition: status + the relevant timestamp (joined_at on join, left_at on leave).
  def status_changeset(%__MODULE__{} = participant, attrs) do
    participant
    |> cast(attrs, [:status, :joined_at, :left_at])
    |> validate_required([:status])
    |> validate_inclusion(:status, @statuses)
  end
end
