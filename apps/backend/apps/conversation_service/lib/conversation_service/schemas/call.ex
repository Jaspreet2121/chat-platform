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
  @kinds ~w(direct group link adhoc)
  @statuses ~w(ringing accepted declined missed ended ongoing cancelled)

  schema "calls" do
    field(:room_name, :string)

    # The session/credential tenant, stamped at the boundary (097). Nullable: pre-097 rows are legacy.
    field(:app_id, :binary_id)
    field(:kind, :string, default: "direct")
    field(:caller_id, :binary_id)
    field(:callee_id, :binary_id)
    field(:conversation_id, :binary_id)

    # Call-link (L1): a "link" call ties back to its call_links row here (nullable — direct/group never set).
    field(:link_id, :string)
    field(:type, :string)
    field(:status, :string, default: "ringing")
    field(:created_at, :utc_datetime_usec)
    field(:answered_at, :utc_datetime_usec)
    field(:ended_at, :utc_datetime_usec)

    # E2EE calls (111 / E2EE_FRAME.md §calls). The caller seals a random 32-byte call key per device;
    # the server relays the envelopes OPAQUELY and never sees the key.
    #
    #   e2ee_offer    — the sealed envelopes, kept only so a push-woken callee can fetch its own.
    #                   SCRUBBED to nil at every terminal status: the key dies with the call.
    #   e2ee          — an offer was made. Survives the scrub; call history reads it for the lock badge.
    #   e2ee_accepted — the callee confirmed it opened its envelope. Survives. nil = never answered.
    field(:e2ee_offer, :map)
    field(:e2ee, :boolean, default: false)
    field(:e2ee_accepted, :boolean)
  end

  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :id,
      :room_name,
      :app_id,
      :kind,
      :caller_id,
      :callee_id,
      :conversation_id,
      :link_id,
      :type,
      :status,
      :created_at,
      :e2ee_offer,
      :e2ee
    ])
    |> validate_required([:id, :room_name, :caller_id, :type, :status, :created_at])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:status, @statuses)
    |> validate_call_shape()
    |> unique_constraint(:room_name)
  end

  # Shape by kind: a DIRECT (1-on-1) call requires a callee (unchanged from Phase 1); a GROUP call has no
  # single callee but MUST belong to a conversation (participants come from that conversation's members); a
  # LINK call (L1) has NEITHER a single callee NOR a conversation — membership is the join-created
  # group_call_participants rows — so it requires neither.
  defp validate_call_shape(changeset) do
    case get_field(changeset, :kind) do
      "group" -> validate_required(changeset, [:conversation_id])
      "link" -> changeset
      # ADHOC (116): like link, membership is ONLY the group_call_participants rows — no conversation,
      # no single callee. Unlike link it is invite-driven; the target checks live in
      # CallStore.create_adhoc_group_call, not here.
      "adhoc" -> changeset
      _ -> validate_required(changeset, [:callee_id])
    end
  end

  # Lifecycle transitions touch status, the relevant timestamp, and the E2EE bits: `e2ee_accepted` is
  # written on answer, and `e2ee_offer` is scrubbed to nil on every terminal status (the caller passes
  # the nil explicitly — see CallStore.transition/3).
  def status_changeset(%__MODULE__{} = call, attrs) do
    call
    |> cast(attrs, [:status, :answered_at, :ended_at, :e2ee_offer, :e2ee_accepted])
    |> validate_required([:status])
    |> validate_inclusion(:status, @statuses)
  end

  # Promote a DIRECT 1-on-1 call to a GROUP call (Phase-3 C3b): flip kind + status, keeping room_name,
  # caller_id, callee_id, and conversation_id. `validate_call_shape` then requires conversation_id (the group
  # invariant), so a direct call with no conversation can't be promoted.
  def promote_changeset(%__MODULE__{} = call, attrs) do
    call
    |> cast(attrs, [:kind, :status])
    |> validate_required([:kind, :status])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_call_shape()
  end
end
