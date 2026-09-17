defmodule MediaService.ViewOnceSweepTriggerTest do
  @moduledoc """
  The sweep's TRIGGER (127): one call per 60 s per node, from `complete_upload`, and never able to
  affect an upload.

  The schedule matters as much as the sweep. It used to ride the view-once OPEN endpoint, which is
  backwards — the sweep collects messages NOBODY OPENED, so its trigger was the one event
  guaranteed to be missing. `complete_upload` is frequent and unrelated.

  The split-release guard is the other half: `SharedInfra.MessageClient`'s default adapter is a
  module from the MESSAGE release, absent from this one, so an unconfigured node must refuse and
  log rather than raise on every upload.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias MediaService.ViewOnceSweepTrigger

  defmodule SweepFake do
    @moduledoc false
    def start_link, do: Agent.start_link(fn -> 0 end, name: __MODULE__)
    def calls, do: Agent.get(__MODULE__, & &1)

    def sweep_view_once_expiry(_attrs) do
      Agent.update(__MODULE__, &(&1 + 1))
      {:ok, %{candidates: 0, purged: 0, failed: 0, dry_run: false}}
    end
  end

  setup do
    prev = Application.get_env(:shared_infra, :message_client_adapter)
    start_supervised!(%{id: SweepFake, start: {SweepFake, :start_link, []}})
    ViewOnceSweepTrigger.__reset__()

    on_exit(fn ->
      ViewOnceSweepTrigger.__reset__()

      if prev,
        do: Application.put_env(:shared_infra, :message_client_adapter, prev),
        else: Application.delete_env(:shared_infra, :message_client_adapter)
    end)

    :ok
  end

  # The trigger runs in an unlinked Task; wait for the side effect rather than sleeping blindly.
  defp await(expected, attempts \\ 200) do
    cond do
      SweepFake.calls() >= expected -> SweepFake.calls()
      attempts == 0 -> SweepFake.calls()
      true -> Process.sleep(5) && await(expected, attempts - 1)
    end
  end

  test "a configured node sweeps once" do
    Application.put_env(:shared_infra, :message_client_adapter, SweepFake)

    assert :ok = ViewOnceSweepTrigger.maybe_sweep()
    assert await(1) == 1
  end

  test "a BURST of uploads triggers exactly ONE sweep — the cap is claimed before the work" do
    Application.put_env(:shared_infra, :message_client_adapter, SweepFake)

    for _ <- 1..50, do: ViewOnceSweepTrigger.maybe_sweep()
    assert await(1) == 1

    # Still one after everything has had time to run.
    Process.sleep(50)
    assert SweepFake.calls() == 1
    assert ViewOnceSweepTrigger.interval_ms() == 60_000
  end

  test "an UNCONFIGURED node refuses, warns ONCE, and never raises" do
    Application.delete_env(:shared_infra, :message_client_adapter)

    log =
      capture_log([level: :warning], fn ->
        assert :ok = ViewOnceSweepTrigger.maybe_sweep()
        Process.sleep(50)
      end)

    assert log =~ "no message client adapter is configured here"
    assert log =~ "MESSAGE_CLIENT_ADAPTER=http"
    assert SweepFake.calls() == 0

    # Once, not per upload.
    ViewOnceSweepTrigger.__reset__()
    :persistent_term.put({ViewOnceSweepTrigger, :unconfigured_warned}, true)

    log =
      capture_log([level: :warning], fn ->
        ViewOnceSweepTrigger.maybe_sweep()
        Process.sleep(50)
      end)

    refute log =~ "no message client adapter"
  end

  test "a RAISING sweep never reaches the caller — an upload is never affected" do
    defmodule Exploding do
      @moduledoc false
      def sweep_view_once_expiry(_attrs), do: raise("boom")
    end

    Application.put_env(:shared_infra, :message_client_adapter, Exploding)

    log =
      capture_log(fn ->
        assert :ok = ViewOnceSweepTrigger.maybe_sweep()
        Process.sleep(50)
      end)

    assert log =~ "upload unaffected" or log =~ "boom"
  end
end
