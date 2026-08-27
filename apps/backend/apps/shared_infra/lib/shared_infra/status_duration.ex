defmodule SharedInfra.StatusDuration do
  @moduledoc """
  The server-owned enum of status durations (112), and the default.

  IT LIVES IN shared_infra BECAUSE TWO RELEASES NEED IT. `MessageService.Statuses` validates writes
  against it, and the API gateway puts it in the `status.invalid_duration` body (and clients render
  their picker from that, rather than hardcoding the values). The gateway release does NOT contain
  `MessageService`, so reaching across for the list would compile here and crash there — the same
  split-release trap that broke the UPI-QR media client.

  The DB carries the same set as a CHECK on `status_audience.duration_hours` (migration 112). Widening
  the enum means changing BOTH — this list and that constraint — or the database refuses the write.
  """

  @allowed [6, 12, 24, 48]
  @default 24

  @doc "Durations a user may choose, ascending."
  @spec allowed() :: [pos_integer()]
  def allowed, do: @allowed

  @doc "The duration for a user who has never set one."
  @spec default() :: pos_integer()
  def default, do: @default

  @doc "True when `hours` is a value the server accepts."
  @spec allowed?(term()) :: boolean()
  def allowed?(hours), do: hours in @allowed
end
