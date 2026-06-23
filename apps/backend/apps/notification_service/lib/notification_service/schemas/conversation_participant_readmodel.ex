defmodule NotificationService.Schemas.ConversationParticipantReadModel do
  @moduledoc """
  Local read-model of conversation membership, built from `conversation.events.v1`
  (`participant_added`/`participant_removed`). Soft state: `active` flips, rows are never
  hard-deleted. `last_event_at` is the `occurred_at` of the last applied event and gates
  last-writer-wins convergence under out-of-order delivery. (c) fan-out reads the active
  set per `conversation_id`. Maintained idempotently by
  `NotificationService.ParticipantReadModel`.
  """

  use Ecto.Schema

  @primary_key false
  schema "conversation_participants_readmodel" do
    field(:conversation_id, :binary_id, primary_key: true)
    field(:user_id, :binary_id, primary_key: true)
    field(:active, :boolean)
    field(:role, :string)
    field(:last_event_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end
end
