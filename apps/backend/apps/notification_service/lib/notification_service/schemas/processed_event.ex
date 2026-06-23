defmodule NotificationService.Schemas.ProcessedEvent do
  @moduledoc """
  notification-service's OWN idempotency ledger, keyed by `(consumer, event_id)`.

  Deliberately NOT shared with message-service's `processed_events`: each service owns its
  own ledger (`notification_processed_events`) so services are not coupled through one
  table. An `INSERT ... ON CONFLICT DO NOTHING` here is the dedupe gate (see
  `NotificationService.Notifications`). This is the per-service blueprint the other
  documented-only services copy.
  """

  use Ecto.Schema

  @primary_key false
  schema "notification_processed_events" do
    field(:consumer, :string, primary_key: true)
    field(:event_id, :binary_id, primary_key: true)
    field(:inserted_at, :utc_datetime_usec)
  end
end
