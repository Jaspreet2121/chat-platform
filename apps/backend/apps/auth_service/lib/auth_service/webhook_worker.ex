defmodule AuthService.WebhookWorker do
  @moduledoc """
  Supervised webhook delivery worker (poll loop). Each tick it claims due outbox rows via
  `SharedInfra.WebhookOutbox.claim_due/2` (FOR UPDATE SKIP LOCKED → multi-replica safe), then delivers
  them with bounded concurrency + a per-row timeout, so one slow/dead endpoint never blocks the queue.
  Delivery (HMAC signing, POST, mark delivered/retry) lives in `SharedInfra.WebhookOutbox`. The loop is
  crash-isolated: a transient DB/network error is logged and the next tick runs (the durable outbox is
  the source of truth — nothing is lost across a restart).
  """

  use GenServer

  require Logger

  @poll_ms 1_000
  @batch 20
  @max_concurrency 8
  @task_timeout_ms 8_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:poll, state) do
    poll()
    schedule()
    {:noreply, state}
  end

  defp poll do
    case SharedInfra.WebhookOutbox.claim_due(AuthService.Repo, @batch) do
      [] ->
        :ok

      rows ->
        rows
        |> Task.async_stream(
          fn row -> SharedInfra.WebhookOutbox.deliver(AuthService.Repo, row) end,
          max_concurrency: @max_concurrency,
          timeout: @task_timeout_ms,
          on_timeout: :kill_task
        )
        |> Stream.run()
    end
  rescue
    error -> Logger.error("[webhook_worker] poll failed: #{Exception.message(error)}")
  catch
    kind, reason -> Logger.error("[webhook_worker] poll crashed: #{inspect({kind, reason})}")
  end

  defp schedule, do: Process.send_after(self(), :poll, @poll_ms)
end
