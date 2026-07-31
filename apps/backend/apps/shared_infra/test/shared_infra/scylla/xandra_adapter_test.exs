defmodule SharedInfra.Scylla.XandraAdapterTest do
  @moduledoc """
  The real Xandra client adapter (Phase B) — DRIVER ONLY; nothing here makes Scylla a store.

  The important test is BOOT SAFETY: message_service serves all production chat from Postgres, so a
  dead or misconfigured Scylla must degrade, never crash. Proven three ways below:
    1. a cluster pointed at a DEAD host still starts (Xandra connects in the background) and, more
       importantly, `start_link/1` NEVER returns an error — it returns :ignore, which a supervisor
       treats as "carry on without this child";
    2. with no cluster running, every callback returns {:error, :scylla_unavailable} — byte-identical
       to the default stub, so MessageStore.ScyllaAdapter keeps mapping it to
       :message_store_unavailable exactly as before;
    3. the option builder converts config into the exact shape Xandra demands.

  The live round-trip against a real container is `@tag :scylla_integration` (excluded by default).
  """
  use ExUnit.Case, async: false

  alias SharedInfra.Scylla.XandraAdapter

  # A port nothing listens on — the "Scylla is down / misconfigured" case.
  @dead_node [{"127.0.0.1", 9099}]
  @cluster SharedInfra.Scylla.XandraAdapter.Cluster

  # The adapter registers its cluster under a FIXED name (right for production: callers look it up
  # rather than holding a pid), so these tests must free that name before AND after each one — else a
  # second start returns {:error, {:already_started, _}} → :ignore, and the suite becomes dependent on
  # ExUnit's random seed order.
  setup do
    ensure_no_cluster()
    on_exit(&ensure_no_cluster/0)
    :ok
  end

  defp ensure_no_cluster do
    case Process.whereis(@cluster) do
      nil -> :ok
      pid -> Supervisor.stop(pid, :normal, 5_000)
    end

    wait_until_unregistered(50)
  catch
    :exit, _ -> wait_until_unregistered(50)
  end

  defp wait_until_unregistered(0), do: :ok

  defp wait_until_unregistered(tries) do
    case Process.whereis(@cluster) do
      nil -> :ok
      _pid -> Process.sleep(20) && wait_until_unregistered(tries - 1)
    end
  end

  defp start_dead_cluster! do
    {:ok, pid} = XandraAdapter.start_link(nodes: @dead_node)
    pid
  end

  describe "boot safety" do
    test "start_link with a DEAD host never returns an error (supervisor carries on)" do
      result = XandraAdapter.start_link(nodes: @dead_node, keyspace: "chat_messages")

      # Either it starts (Xandra retries in the background — the healthy outcome) or it declines with
      # :ignore. What it must NEVER do is return {:error, _}, which would abort the supervisor and
      # take message_service down with it.
      case result do
        {:ok, pid} when is_pid(pid) ->
          assert Process.alive?(pid)
          Supervisor.stop(pid)

        :ignore ->
          :ok

        other ->
          flunk("start_link must never fail the supervisor, got: #{inspect(other)}")
      end
    end

    test "a dead cluster DEGRADES: execute/prepare return errors, never raise" do
      pid = start_dead_cluster!()

      # No connection will ever establish, so calls must come back as errors — not exceptions, not
      # hangs beyond the timeout.
      assert {:error, _reason} =
               XandraAdapter.execute("SELECT release_version FROM system.local", [], timeout: 500)

      assert {:error, _reason} =
               XandraAdapter.prepare("SELECT release_version FROM system.local", timeout: 500)

      Supervisor.stop(pid)
    end

    test "with NO cluster started, callbacks return :scylla_unavailable (the stub's contract)" do
      refute Process.whereis(@cluster), "setup must leave no cluster running"

      assert {:error, :scylla_unavailable} = XandraAdapter.execute("SELECT 1", [])
      assert {:error, :scylla_unavailable} = XandraAdapter.prepare("SELECT 1")
    end

    test "the child spec is transient and starts through start_link/1" do
      spec = XandraAdapter.child_spec(nodes: @dead_node)

      assert spec.id == XandraAdapter
      assert spec.restart == :transient
      assert {XandraAdapter, :start_link, [_opts]} = spec.start
    end
  end

  describe "cluster_options/1" do
    test "converts Config.Scylla's {host, port} TUPLES into Xandra's \"host:port\" strings" do
      opts = XandraAdapter.cluster_options(nodes: [{"scylla", 9042}, {"other", 9043}])

      assert opts[:nodes] == ["scylla:9042", "other:9043"]
    end

    test "never blocks boot: sync_connect is off" do
      assert XandraAdapter.cluster_options(nodes: [{"scylla", 9042}])[:sync_connect] == false
    end

    test "passes the keyspace through (Xandra USEs it per connection), and omits it when unset" do
      assert XandraAdapter.cluster_options(nodes: [{"s", 9042}], keyspace: "chat_messages")[
               :keyspace
             ] == "chat_messages"

      refute Keyword.has_key?(XandraAdapter.cluster_options(nodes: [{"s", 9042}]), :keyspace)

      refute Keyword.has_key?(
               XandraAdapter.cluster_options(nodes: [{"s", 9042}], keyspace: ""),
               :keyspace
             )
    end

    test "accepts contact_points (Config.Scylla emits both keys) and plain strings" do
      assert XandraAdapter.cluster_options(contact_points: [{"a", 9042}])[:nodes] == ["a:9042"]
      assert XandraAdapter.cluster_options(nodes: ["b:9042"])[:nodes] == ["b:9042"]
    end
  end

  describe "adapter selection (the boundary is unchanged unless explicitly configured)" do
    test "the DEFAULT is still the unavailable stub" do
      previous = Application.get_env(:shared_infra, :scylla_client_adapter)
      Application.delete_env(:shared_infra, :scylla_client_adapter)

      on_exit(fn ->
        if previous, do: Application.put_env(:shared_infra, :scylla_client_adapter, previous)
      end)

      assert SharedInfra.Scylla.Client.adapter() == SharedInfra.Scylla.UnavailableClient
      assert SharedInfra.Scylla.Client.execute("SELECT 1", []) == {:error, :scylla_unavailable}
    end

    test "config selects this adapter when set (what runtime.exs does under SCYLLA_NODES)" do
      previous = Application.get_env(:shared_infra, :scylla_client_adapter)
      Application.put_env(:shared_infra, :scylla_client_adapter, XandraAdapter)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:shared_infra, :scylla_client_adapter, previous),
          else: Application.delete_env(:shared_infra, :scylla_client_adapter)
      end)

      assert SharedInfra.Scylla.Client.adapter() == XandraAdapter
      # Dispatches to us — and with no cluster running, degrades exactly like the stub.
      assert SharedInfra.Scylla.Client.execute("SELECT 1", []) == {:error, :scylla_unavailable}
    end

    test "the TEST adapter is undisturbed (suites keep using the fake)" do
      assert {:ok, %{adapter: SharedInfra.TestAdapters.Scylla, statement: "SELECT 1", params: []}} =
               SharedInfra.TestAdapters.Scylla.execute("SELECT 1", [])
    end
  end

  # --- live container round-trip (excluded by default) --------------------------------------------
  # Run against a real Scylla:
  #   docker compose -f docker-compose.prod.yml --profile scylla up -d scylla
  #   SCYLLA_TEST_NODES=localhost:9042 mix test --include scylla_integration
  # NOTE: deliberately a READ against system.local — this phase writes NOTHING into
  # messages_by_conversation, because the write plans' bucket_date/timestamp/metadata encodings do not
  # match the CQL column types yet (Phase D). A write smoke here would put junk in a table whose
  # migration is still undesigned.
  describe "live cluster" do
    @tag :scylla_integration
    test "round-trips SELECT release_version FROM system.local" do
      nodes =
        System.get_env("SCYLLA_TEST_NODES", "localhost:9042")
        |> String.split(",", trim: true)

      {:ok, pid} = XandraAdapter.start_link(nodes: nodes)
      # Give the background connect a moment (sync_connect is deliberately off).
      # (setup/on_exit guarantee the registered name is free before and after.)
      Process.sleep(2_000)

      assert {:ok, %{rows: rows}} =
               XandraAdapter.execute("SELECT release_version FROM system.local", [],
                 timeout: 5_000
               )

      assert [%{"release_version" => version}] = rows
      assert is_binary(version)

      Supervisor.stop(pid)
    end
  end
end
