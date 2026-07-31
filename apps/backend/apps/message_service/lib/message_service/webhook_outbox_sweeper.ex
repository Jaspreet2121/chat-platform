defmodule MessageService.WebhookOutboxSweeper do
  @moduledoc """
  Resolves STAGED webhook-outbox rows the write-ahead intent left behind (C6): a crash between the
  Scylla put and the promote strands the row as 'staged'. Every sweep, rows staged for longer than
  the stale window are checked against the AUTHORITATIVE store:

    * message exists    -> promote (idempotent: only 'staged' flips — a row promoted by a racing
                           caller whose response was lost is simply not matched again);
    * message absent    -> mark 'aborted', KEPT with last_error naming this sweeper — evidence that
                           a write was attempted and lost, visible to an operator
                           (SELECT * FROM webhook_outbox WHERE status='aborted');
    * store unavailable -> leave staged, next sweep retries. NEVER abort on an outage — absence must
                           be proven by the store answering, not inferred from it not answering.

  Delivery lag in the crash window is therefore bounded by ONE SWEEP INTERVAL (default 60s,
  WEBHOOK_SWEEP_INTERVAL_SECONDS) + the stale window (60s). Stated in the integration guide.
  """

  use GenServer

  require Logger

  alias MessageService.MessageStore.ScyllaAdapter
  alias MessageService.Repo

  @default_interval_seconds 60
  @stale_seconds 60

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_seconds, configured_interval())
    if Keyword.get(opts, :schedule, true), do: schedule(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:sweep, state) do
    try do
      sweep()
    rescue
      error -> Logger.error("webhook outbox sweep failed: #{Exception.message(error)}")
    end

    schedule(state.interval)
    {:noreply, state}
  end

  @doc "One pass, callable directly (tests, operators). Returns %{promoted: n, aborted: n, left: n}."
  def sweep(stale_seconds \\ @stale_seconds) do
    Repo
    |> SharedInfra.WebhookOutbox.stale_staged(stale_seconds)
    |> Enum.reduce(%{promoted: 0, aborted: 0, left: 0}, fn row, acc ->
      case resolve(row) do
        :promoted -> %{acc | promoted: acc.promoted + 1}
        :aborted -> %{acc | aborted: acc.aborted + 1}
        :left -> %{acc | left: acc.left + 1}
      end
    end)
    |> tap(fn %{promoted: p, aborted: a, left: l} ->
      if p + a + l > 0 do
        Logger.warning(
          "webhook outbox sweep: promoted=#{p} aborted=#{a} left=#{l} " <>
            "(staged rows are crash-window evidence — aborted ones are KEPT for operators)"
        )
      end
    end)
  end

  defp resolve(%{id: id, payload: payload}) do
    conversation_id = payload["conversation_id"]
    message_id = payload["message_id"]

    case ScyllaAdapter.get_message(%{
           "conversation_id" => conversation_id,
           "message_id" => message_id
         }) do
      {:ok, _message} ->
        {:ok, _} = SharedInfra.WebhookOutbox.promote_staged(Repo, [id])
        :promoted

      {:error, :message_not_found} ->
        {:ok, _} =
          SharedInfra.WebhookOutbox.abort_staged(
            Repo,
            [id],
            "authoritative write never landed (sweeper checked scylla; message absent)"
          )

        :aborted

      {:error, _unavailable} ->
        :left
    end
  end

  defp schedule(interval), do: Process.send_after(self(), :sweep, interval * 1000)

  defp configured_interval do
    case Integer.parse(System.get_env("WEBHOOK_SWEEP_INTERVAL_SECONDS") || "") do
      {n, _} when n > 0 -> n
      _ -> @default_interval_seconds
    end
  end
end
