defmodule ApiGatewayWeb.CallReaper do
  @moduledoc """
  The backstop for group rings whose timer died (130-group).

  A group/adhoc ring timeout is a `Process.send_after` in the initiator's channel process. If that
  socket drops before it fires, the timer dies with it: invited rows never flip to missed, the call
  stays `ringing` forever, and nobody is told `call:group_ended`. This finishes those timeouts late,
  by running the EXACT handler the timer would have — `CallSignaling.group_ring_timeout/2`, with this
  release's endpoint standing in for the socket — so a reaped call ends the way a timed-out one does.

  THERE IS NO SCHEDULER IN THIS SYSTEM, so maintenance rides a request (the view-once sweep's
  pattern): every call endpoint calls `maybe_reap/0`, which claims a 60 s slot per node and does the
  work in a Task. Never raises, never blocks the caller.

  DELIBERATELY NOT HERE: closing `ongoing` calls on a clock. A long real call looks identical to an
  abandoned one from the database, and ending it would send `call:group_ended` to people mid-call.
  That needs a signal from the media plane (LiveKit room/participant webhooks) — recorded in the
  roadmap, not built.
  """

  require Logger

  @claim_key {__MODULE__, :last_run_ms}
  @interval_ms 60_000
  # Ring window + slack. The timer itself fires at ring_timeout_ms; a call still ringing this long
  # after creation has a dead timer, not a slow one.
  @slack_seconds 25

  @doc "The run-once-per-node interval, in ms."
  def interval_ms, do: @interval_ms

  @doc "How old (seconds since created) a still-ringing group call must be before it is reaped."
  def cutoff_seconds,
    do: div(RealtimeGateway.CallSignaling.ring_timeout_ms(), 1000) + @slack_seconds

  @doc "Reap if this node has not in the last #{@interval_ms} ms. Always :ok; async; never raises."
  def maybe_reap do
    if claim() do
      Task.start(fn -> reap_now() end)
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc "Reap synchronously, ignoring the guard (tests, and a future admin trigger). Returns the ids reaped."
  def reap_now do
    case SharedInfra.ConversationClient.list_stale_ringing_group_calls(%{
           "older_than_seconds" => cutoff_seconds()
         }) do
      {:ok, result} ->
        ids = Map.get(result, :call_ids) || Map.get(result, "call_ids") || []

        Enum.each(ids, fn call_id ->
          RealtimeGateway.CallSignaling.group_ring_timeout(call_id, %{
            endpoint: ApiGatewayWeb.Endpoint
          })
        end)

        if ids != [],
          do: Logger.info("call reaper: finished #{length(ids)} dead group ring timeout(s)")

        ids

      other ->
        Logger.warning("call reaper: stale-call read failed, skipped: #{inspect(other)}")
        []
    end
  rescue
    error ->
      Logger.warning("call reaper raised, ignored: #{inspect(error)}")
      []
  end

  @doc false
  def reset_guard, do: :persistent_term.erase(@claim_key)

  defp claim do
    now = System.monotonic_time(:millisecond)
    last = :persistent_term.get(@claim_key, nil)

    if is_nil(last) or now - last >= @interval_ms do
      :persistent_term.put(@claim_key, now)
      true
    else
      false
    end
  end
end
