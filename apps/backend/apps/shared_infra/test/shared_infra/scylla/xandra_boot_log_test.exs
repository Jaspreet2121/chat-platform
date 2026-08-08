defmodule SharedInfra.Scylla.XandraBootLogTest do
  @moduledoc """
  Pins the adapter's boot line — which was NEVER pinned before, and lied for it: the original
  wording ("driver only, store is postgres") was written in Phase B when it was true and printed a
  falsehood on every boot from the 2026-08-08 cutover until it was fixed, in the one place an
  operator looks first. The rule the new line follows: log only what THIS module knows (the cluster
  started, on which nodes) — never another app's runtime config.

  Docker-free: `sync_connect` is off by design, so `start_link` succeeds without any reachable node
  and the line is capturable without a cluster.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SharedInfra.Scylla.XandraAdapter

  @cluster SharedInfra.Scylla.XandraAdapter.Cluster

  test "the boot line names the nodes and claims NOTHING about the selected store" do
    ensure_no_cluster()

    log =
      capture_log(fn ->
        {:ok, pid} = XandraAdapter.start_link(nodes: ["nowhere.invalid:9042"])
        Supervisor.stop(pid, :normal, 5_000)
      end)

    assert log =~ ~s{scylla: Xandra cluster started (["nowhere.invalid:9042"])}

    # The stale-claim class this guards: the adapter must not assert which store is selected —
    # that is :message_service runtime config it cannot see, and any wording about it goes stale
    # the moment the config changes.
    refute log =~ "store is"
    refute log =~ "driver only"
  end

  defp ensure_no_cluster do
    case Process.whereis(@cluster) do
      nil -> :ok
      pid -> Supervisor.stop(pid, :normal, 5_000)
    end
  end
end
