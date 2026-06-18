defmodule NotificationService.Schemas.Notification do
  @moduledoc """
  A notification record. The first slice writes ONE record per `message.created.v1`
  (`type: "message_created"`), capturing the source event reference and the message
  facts (sender/conversation/message ids). No recipient yet — recipient fan-out (one
  record per conversation participant) is a deferred slice that needs participant data
  from ConversationService.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "notifications" do
    field(:type, :string)
    field(:source_event_id, :binary_id)
    field(:conversation_id, :binary_id)
    field(:message_id, :binary_id)
    field(:sender_user_id, :binary_id)
    field(:read, :boolean, default: false)
    field(:created_at, :utc_datetime_usec)
    field(:inserted_at, :utc_datetime_usec)
  end
end
