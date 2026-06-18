defmodule MessageService.Schemas.ProcessedEvent do
  @moduledoc """
  Idempotency ledger for event consumers, keyed by `(consumer, event_id)`.

  Each consumer records the events it has applied; an `INSERT ... ON CONFLICT DO
  NOTHING` against this table is the dedupe gate (see
  `MessageService.Projections.ConversationSummary`). Per-consumer scope so multiple
  consumers dedupe independently. This is the reusable pattern for future consumers.
  """

  use Ecto.Schema

  @primary_key false
  schema "processed_events" do
    field(:consumer, :string, primary_key: true)
    field(:event_id, :binary_id, primary_key: true)
    field(:inserted_at, :utc_datetime_usec)
  end
end
