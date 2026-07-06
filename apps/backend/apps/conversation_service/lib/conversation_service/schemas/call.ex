defmodule ConversationService.Schemas.Call do
  @moduledoc """
  Ecto schema for the `calls` table (Phase-1 LiveKit calling). One row per 1-on-1 call: caller/callee,
  the LiveKit room_name, type, lifecycle status, and timestamps for history/missed-call entries.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}

  @types ~w(voice video)
  @statuses ~w(ringing accepted declined missed ended)

  schema "calls" do
    field(:room_name, :string)
    field(:caller_id, :binary_id)
    field(:callee_id, :binary_id)
    field(:conversation_id, :binary_id)
    field(:type, :string)
    field(:status, :string, default: "ringing")
    field(:created_at, :utc_datetime_usec)
    field(:answered_at, :utc_datetime_usec)
    field(:ended_at, :utc_datetime_usec)
  end

  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :id,
      :room_name,
      :caller_id,
      :callee_id,
      :conversation_id,
      :type,
      :status,
      :created_at
    ])
    |> validate_required([:id, :room_name, :caller_id, :callee_id, :type, :status, :created_at])
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:room_name)
  end

  # Lifecycle transitions only touch status + the relevant timestamp.
  def status_changeset(%__MODULE__{} = call, attrs) do
    call
    |> cast(attrs, [:status, :answered_at, :ended_at])
    |> validate_required([:status])
    |> validate_inclusion(:status, @statuses)
  end
end
