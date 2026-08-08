defmodule ConversationService.InboxReconciler do
  @moduledoc """
  The MANDATORY drift backstop for the denormalised inbox row (086) — not an optional nicety.

  The maintained counters are transaction-exact under the Postgres store, but two drift sources are
  accepted by design rather than engineered away (see InboxProjection's honesty rules): cross-store
  partial failure once messages move to Scylla, and the non-idempotent decrement under a
  double-delivered read receipt (making it exact would mean per-(message,user) dedup state in
  Postgres — receipts-in-Postgres again — or a Paxos round per receipt). Drift is bounded (clamped at
  0, ±small), self-healing on any recount path, and THIS process is the guarantee that it heals even
  for rows nobody reads: every `interval`, recount every active participant of every conversation
  with activity in the last `lookback`.

  Off in :test at boot (persistence is flipped per-test, after supervision); tests call
  `InboxCounters.reconcile_conversation/1` directly. In dev/prod it runs whenever the conversation
  store is DB-backed. This same comparator becomes C7's dual-write verification tool.

  ## IT STILL TICKS UNDER SCYLLA, AND THAT IS DELIBERATE

  The store interlock is NOT here. This process keeps its timer and keeps calling
  `InboxCounters.reconcile_recent/2`, which refuses the work itself and logs why. The gate lives on
  the InboxCounters functions because this reconciler is only one of four callers of the same
  store-bound SQL — the inbox read-repair, `set_auto_delete` and a participant rejoin reach it
  without passing through here. Gating the child spec or the timer would have looked like a fix and
  left three live paths recounting from a frozen table.
  """

  use GenServer

  require Logger

  @default_interval_seconds 300
  @lookback_seconds 3_600
  @batch_limit 200

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_seconds, configured_interval())

    if enabled?() do
      schedule(interval)
    end

    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:reconcile, state) do
    try do
      count = ConversationService.InboxCounters.reconcile_recent(@lookback_seconds, @batch_limit)

      if count > 0 do
        Logger.debug("inbox reconciler: recounted #{count} recently-active conversation(s)")
      end
    rescue
      # The backstop must never crash-loop the service it protects — log loudly, tick again.
      error ->
        Logger.error("inbox reconciler pass failed: #{Exception.message(error)}")
    end

    schedule(state.interval)
    {:noreply, state}
  end

  defp schedule(interval), do: Process.send_after(self(), :reconcile, interval * 1000)

  defp enabled? do
    Application.get_env(:conversation_service, :conversation_persistence, false) ||
      System.get_env("CONVERSATION_DB_BACKED") in ["true", "1", "yes"]
  end

  defp configured_interval do
    case Integer.parse(System.get_env("INBOX_RECONCILER_INTERVAL_SECONDS") || "") do
      {n, _} when n > 0 -> n
      _ -> @default_interval_seconds
    end
  end
end
