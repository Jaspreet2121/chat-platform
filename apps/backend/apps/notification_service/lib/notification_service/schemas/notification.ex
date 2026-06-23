defmodule NotificationService.Schemas.Notification do
  @moduledoc """
  A notification record, written one-per-RECIPIENT by the `message.created.v1` fan-out
  (`type: "message_created"`): `recipient_user_id` is who is notified (an active conversation
  participant, excluding the sender), `sender_user_id` is who sent the message. Idempotency
  per `(source_event_id, recipient_user_id)` via a UNIQUE index (see
  `NotificationService.Notifications`).
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "notifications" do
    field(:type, :string)
    field(:source_event_id, :binary_id)
    field(:recipient_user_id, :binary_id)
    field(:conversation_id, :binary_id)
    field(:message_id, :binary_id)
    field(:sender_user_id, :binary_id)
    field(:read, :boolean, default: false)
    field(:created_at, :utc_datetime_usec)
    field(:inserted_at, :utc_datetime_usec)
  end
end
