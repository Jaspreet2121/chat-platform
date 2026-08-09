defmodule MessageService.EventOutboxRelay do
  @moduledoc """
  The event outbox's forward pump — the C6 `WebhookOutboxSweeper` precedent, cited deliberately:
  like that sweeper it moves rows FORWARD through a one-way state machine exactly once (pending →
  published-and-deleted; stale-staged → resolved against the authoritative store) and it NEVER
  recomputes state from another table. That is the whole difference from the reconciler this repo
  gated: a reconciler derives state from a second source and overwrites; a relay delivers intent
  that already exists and then forgets it.

  Runs where the repo runs, gated by the SAME flag as publishing (`KAFKA_PUBLISH_ENABLED`): flag
  off ⇒ every pass no-ops and mid-flight rows SIT untouched until the flag returns (deliberate —
  their Scylla writes happened; dropping them would be the loss this machinery ends).

  Cadence bounds the recovery lag exactly as C6's does: a crash-window event publishes within one
  sweep interval + the stale window (defaults 30s + 60s) of the broker being reachable.
  """

  use GenServer

  require Logger

  @default_interval_seconds 30

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_seconds, configured_interval())
    if Keyword.get(opts, :schedule, true), do: schedule(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:relay, state) do
    try do
      case MessageService.EventOutbox.relay_pass() do
        %{skipped: true} ->
          :ok

        counts ->
          if (counts[:published] || 0) + (counts[:promoted] || 0) + (counts[:aborted] || 0) > 0 do
            Logger.info("event outbox relay: #{inspect(counts)}")
          end
      end
    rescue
      # The pump must never crash-loop the service it protects — log loudly, tick again.
      error -> Logger.error("event outbox relay pass failed: #{Exception.message(error)}")
    end

    schedule(state.interval)
    {:noreply, state}
  end

  defp schedule(interval), do: Process.send_after(self(), :relay, interval * 1000)

  defp configured_interval do
    case Integer.parse(System.get_env("EVENT_OUTBOX_RELAY_INTERVAL_SECONDS") || "") do
      {n, _} when n > 0 -> n
      _ -> @default_interval_seconds
    end
  end
end
