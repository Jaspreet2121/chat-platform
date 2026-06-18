defmodule NotificationService do
  @moduledoc """
  Notification service boundary.

  Consumes `message.created.v1` and records notifications. The first slice creates ONE
  notification record per event (no recipient fan-out); recipient resolution (per
  conversation participant) is deferred to a later slice since `message.created.v1`
  carries the sender, not recipients.
  """
end
