defmodule ConversationService.Schemas.Call do
  @moduledoc """
  Ecto schema for the `calls` table (LiveKit calling). One row per call: caller (+ callee for a `direct`
  1-on-1 call), the LiveKit room_name, type, lifecycle status, and timestamps. `kind` = "direct" (Phase 1/2
  1-on-1) or "group" (Phase 3 — no single callee; membership lives in `call_participants`).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}

  @types ~w(voice video)
  @kinds ~w(direct group)
  @statuses ~w(ringing accepted declined missed ended ongoing)

  schema "calls" do
    field(:room_name, :string)
    field(:kind, :string, default: "direct")
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
      :kind,
      :caller_id,
      :callee_id,
      :conversation_id,
      :type,
      :status,
      :created_at
    ])
    |> validate_required([:id, :room_name, :caller_id, :type, :status, :created_at])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:status, @statuses)
    |> validate_call_shape()
    |> unique_constraint(:room_name)
  end

  # Shape by kind: a DIRECT (1-on-1) call requires a callee (unchanged from Phase 1); a GROUP call has no
  # single callee but MUST belong to a conversation (participants come from that conversation's members).
  defp validate_call_shape(changeset) do
    case get_field(changeset, :kind) do
      "group" -> validate_required(changeset, [:conversation_id])
      _ -> validate_required(changeset, [:callee_id])
    end
  end

  # Lifecycle transitions only touch status + the relevant timestamp.
  def status_changeset(%__MODULE__{} = call, attrs) do
    call
    |> cast(attrs, [:status, :answered_at, :ended_at])
    |> validate_required([:status])
    |> validate_inclusion(:status, @statuses)
  end
end
