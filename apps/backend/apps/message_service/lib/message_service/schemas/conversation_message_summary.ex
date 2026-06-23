defmodule MessageService.Schemas.ConversationMessageSummary do
  @moduledoc """
  Per-conversation projection built from `message.created.v1`: running message
  count + last-message pointer. Maintained idempotently (deduped by event_id) by
  `MessageService.Projections.ConversationSummary`.
  """

  use Ecto.Schema

  @primary_key {:conversation_id, :binary_id, autogenerate: false}

  schema "conversation_message_summaries" do
    field(:message_count, :integer, default: 0)
    field(:last_message_id, :binary_id)
    field(:last_message_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end
end
