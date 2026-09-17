defmodule MediaService.ViewOnceSweepTrigger do
  @moduledoc """
  Rides `complete_upload` to run the view-once expiry sweep (127) in the message service.

  ## Why here, of all places

  There is no scheduler in this system, so maintenance rides a request. The sweep USED to ride the
  view-once OPEN endpoint — which is precisely backwards: the sweep exists to collect messages
  **nobody opened**, so on a quiet week it never ran at all, and the one event guaranteed to be
  absent was its own trigger. `complete_upload` is frequent, entirely unrelated to opens, and is
  already a media-service write, so a maintenance hop costs nothing a user waits on.

  ## Bounded

  ONE sweep per 60 seconds per node, claimed with an atomic compare-and-swap in `:persistent_term`
  before the work starts — a burst of uploads triggers exactly one. The call itself runs in an
  unlinked Task and every outcome is swallowed: an upload must never fail, slow down, or change
  behaviour because a maintenance hop did.

  ## The split-release trap

  media-service is its OWN RELEASE. `SharedInfra.MessageClient`'s default adapter is
  `MessageService.MessageClientInProcess`, a module that does not exist in this release — calling it
  raises `UndefinedFunctionError` at runtime while compiling perfectly in the umbrella. That is the
  recorded trap (it has bitten the UPI QR media client and the status sweep's purge before). So this
  refuses to call unless an adapter is explicitly configured, and says so ONCE rather than raising
  on every upload.
  """

  require Logger

  @interval_ms 60_000
  @claim_key {__MODULE__, :last_run_ms}
  @warn_key {__MODULE__, :unconfigured_warned}

  @doc "The minimum gap between sweeps on one node, in milliseconds."
  def interval_ms, do: @interval_ms

  @doc """
  Run the sweep if this node has not run one in the last #{@interval_ms} ms. Always `:ok`; never
  raises, never blocks the caller.
  """
  def maybe_sweep do
    if claim() do
      Task.start(fn -> run() end)
    end

    :ok
  rescue
    _ -> :ok
  end

  # Compare-and-swap on the clock. Claiming BEFORE the work (rather than stamping after) is what
  # makes a burst safe: fifty concurrent uploads all read the same old value, exactly one writes the
  # new one, and only that one proceeds.
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

  defp run do
    if configured?() do
      SharedInfra.MessageClient.sweep_view_once_expiry(%{})
    else
      warn_once()
    end

    :ok
  rescue
    error ->
      Logger.warning("view_once sweep trigger failed (upload unaffected): #{inspect(error)}")
      :ok
  catch
    kind, value ->
      Logger.warning("view_once sweep trigger #{kind} (upload unaffected): #{inspect(value)}")
      :ok
  end

  # An adapter must be EXPLICITLY configured. The default is a module from another release; see the
  # moduledoc.
  defp configured? do
    case Application.get_env(:shared_infra, :message_client_adapter) do
      nil -> false
      module -> Code.ensure_loaded?(module)
    end
  end

  defp warn_once do
    if :persistent_term.get(@warn_key, false) == false do
      :persistent_term.put(@warn_key, true)

      Logger.warning(
        "view_once expiry sweep NOT running from media-service: no message client adapter is " <>
          "configured here. Set MESSAGE_CLIENT_ADAPTER=http and MESSAGE_SERVICE_URL on the media " <>
          "service. Uploads are unaffected; expired view-once blobs are simply not being collected."
      )
    end

    :ok
  end

  @doc false
  # Tests only: forget the claim so the next call is allowed to run.
  def __reset__ do
    :persistent_term.erase(@claim_key)
    :persistent_term.erase(@warn_key)
    :ok
  end
end
