defmodule MessageService.Kafka.LagMonitorTest do
  @moduledoc """
  THE CONSUMER-LAG ALARM. Before it, nothing noticed a stalled group — it was found by running the
  describe command by hand, which means it was found when somebody thought to look.

  Driven against a stub reader rather than a broker. What is under test is the DECISION — which
  group alarms, which stays silent, and whether the number on the health endpoint is honest about
  its own age — none of which is Kafka's behaviour.

  The mutation guards these carry:

    * MUT-1 a stalled group produces no WARN → RED
    * MUT-2 a deliberately-off group alarms → RED
    * MUT-3 the health endpoint reports stale numbers (cached forever) → RED
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias MessageService.Kafka.LagMonitor
  alias SharedInfra.Kafka.ConsumerGroups

  @topic "message.events.v1"

  defmodule StubReader do
    @moduledoc false
    @behaviour SharedInfra.Kafka.LagReader

    def set(state), do: Application.put_env(:message_service, :lag_stub, state)
    defp get, do: Application.get_env(:message_service, :lag_stub, %{})

    @impl true
    def member_counts(_endpoints, _group_ids), do: {:ok, Map.get(get(), :members, %{})}

    @impl true
    def committed_offsets(_endpoints, group_id) do
      case Map.get(get(), :committed, %{}) do
        %{^group_id => offsets} -> {:ok, offsets}
        _ -> {:ok, %{}}
      end
    end

    @impl true
    def latest_offsets(_endpoints, topic),
      do: {:ok, Map.get(get(), :latest, %{}) |> Map.get(topic, %{})}
  end

  setup do
    previous = Application.get_env(:shared_infra, :kafka_lag_reader)
    Application.put_env(:shared_infra, :kafka_lag_reader, StubReader)

    on_exit(fn ->
      Application.delete_env(:message_service, :lag_stub)

      if previous,
        do: Application.put_env(:shared_infra, :kafka_lag_reader, previous),
        else: Application.delete_env(:shared_infra, :kafka_lag_reader)
    end)

    :ok
  end

  # Every group off except the named ones, which get one member each.
  defp members(on),
    do: Map.new(ConsumerGroups.ids(), fn id -> {id, if(id in on, do: 1, else: 0)} end)

  defp start!(opts \\ []) do
    name = :"lag_monitor_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        %{
          id: name,
          start:
            {LagMonitor, :start_link,
             [Keyword.merge([name: name, endpoints: [], poll_on_start: false], opts)]}
        },
        id: name
      )

    {pid, name}
  end

  defp row(snapshot, group_id), do: Enum.find(snapshot.groups, &(&1.group_id == group_id))

  describe "the two alarms" do
    test "MUT-1 guard: a STALLED group warns — lag above zero and the offset has not moved" do
      group = "message-service-inbox-projection"

      StubReader.set(%{
        members: members([group]),
        latest: %{@topic => Map.new(0..5, &{&1, 100})},
        committed: %{group => Map.new(0..5, &{{@topic, &1}, 90})}
      })

      {_pid, name} = start!()

      # First poll establishes the baseline; nothing is known to be stuck yet.
      first = capture_log(fn -> LagMonitor.poll_now(name) end)
      refute first =~ "STALLED"

      # Second poll, identical offsets: the group has not moved while it still has work.
      log = capture_log(fn -> LagMonitor.poll_now(name) end)
      assert log =~ "[warning]"
      assert log =~ "STALLED"
      assert log =~ group
      assert row(LagMonitor.snapshot(name), group).status == "stalled"
    end

    test "a group over the threshold warns as BEHIND even while it is still moving" do
      group = "message-service-search-index"

      StubReader.set(%{
        members: members([group]),
        latest: %{@topic => Map.new(0..5, &{&1, 10_000})},
        committed: %{group => Map.new(0..5, &{{@topic, &1}, 0})}
      })

      {_pid, name} = start!(threshold: 1_000)

      log = capture_log(fn -> LagMonitor.poll_now(name) end)
      assert log =~ "[warning]"
      assert log =~ "BEHIND"
      assert log =~ "lag=60000"

      assert row(LagMonitor.snapshot(name), group).lag == 60_000
    end

    test "a group that is keeping up is silent" do
      group = "message-service-inbox-projection"

      StubReader.set(%{
        members: members([group]),
        latest: %{@topic => Map.new(0..5, &{&1, 100})},
        committed: %{group => Map.new(0..5, &{{@topic, &1}, 100})}
      })

      {_pid, name} = start!()
      log = capture_log(fn -> LagMonitor.poll_now(name) end)

      refute log =~ "[warning]"
      assert row(LagMonitor.snapshot(name), group).status == "ok"
    end
  end

  describe "deliberately off" do
    test "MUT-2 guard: a group with NO members never alarms, however far behind the topic is" do
      off = "message-service-conversation-summary"

      StubReader.set(%{
        # Nobody has joined any group, and the topic is a long way ahead of all of them.
        members: members([]),
        latest: %{@topic => Map.new(0..5, &{&1, 1_000_000})},
        committed: %{}
      })

      {_pid, name} = start!()
      log = capture_log(fn -> LagMonitor.poll_now(name) end)

      refute log =~ "[warning]"

      snapshot = LagMonitor.snapshot(name)
      assert row(snapshot, off).status == "off"
      assert row(snapshot, off).lag == nil
      assert snapshot.status == "ok"
    end

    test "switching one ON needs no code change — it alarms as soon as it has a member" do
      group = "message-service-log-consumer"
      latest = %{@topic => Map.new(0..5, &{&1, 50_000})}

      StubReader.set(%{members: members([]), latest: latest, committed: %{}})
      {_pid, name} = start!(threshold: 1_000)

      refute capture_log(fn -> LagMonitor.poll_now(name) end) =~ "[warning]"
      assert row(LagMonitor.snapshot(name), group).status == "off"

      # The ONLY thing that changed is that somebody joined the group — no list was edited.
      StubReader.set(%{
        members: members([group]),
        latest: latest,
        committed: %{group => Map.new(0..5, &{{@topic, &1}, 0})}
      })

      log = capture_log(fn -> LagMonitor.poll_now(name) end)
      assert log =~ "BEHIND"
      assert row(LagMonitor.snapshot(name), group).status == "behind"
    end

    test "the monitor covers notification-service's groups too — lag is read from the cluster" do
      group = "notification-service-call-incoming"

      StubReader.set(%{
        members: members([group]),
        latest: %{"call.events.v1" => Map.new(0..2, &{&1, 500})},
        committed: %{group => Map.new(0..2, &{{"call.events.v1", &1}, 100})}
      })

      {_pid, name} = start!(threshold: 100)
      log = capture_log(fn -> LagMonitor.poll_now(name) end)

      assert log =~ "BEHIND"
      assert log =~ group
      assert row(LagMonitor.snapshot(name), group).service == "notification"
    end
  end

  describe "freshness" do
    test "MUT-3 guard: a snapshot older than its window reports STALE, not its cached numbers" do
      group = "message-service-inbox-projection"

      StubReader.set(%{
        members: members([group]),
        latest: %{@topic => Map.new(0..5, &{&1, 10})},
        committed: %{group => Map.new(0..5, &{{@topic, &1}, 10})}
      })

      {_pid, name} = start!(stale_after_seconds: 0)
      LagMonitor.poll_now(name)

      fresh = LagMonitor.snapshot(name)
      assert fresh.stale == false
      assert fresh.status == "ok"
      assert is_integer(fresh.age_seconds)
      assert is_binary(fresh.checked_at)

      # One second later the snapshot is past its window. The numbers in it have not changed; what
      # changed is that nobody has refreshed them, and the endpoint must say so.
      Process.sleep(1_100)
      stale = LagMonitor.snapshot(name)

      assert stale.stale == true
      assert stale.status == "stale"
      assert stale.age_seconds >= 1
    end

    test "before the first poll the snapshot is unavailable, not a green zero" do
      {_pid, name} = start!()
      snapshot = LagMonitor.snapshot(name)

      assert snapshot.status == "unavailable"
      assert snapshot.stale == true
      assert snapshot.groups == []
    end

    test "a broker that cannot be read is UNKNOWN and warns — never silently zero" do
      group = "message-service-inbox-projection"

      defmodule BrokenReader do
        @behaviour SharedInfra.Kafka.LagReader
        @impl true
        def member_counts(_e, ids), do: {:ok, Map.new(ids, &{&1, 1})}
        @impl true
        def committed_offsets(_e, _g), do: {:error, :econnrefused}
        @impl true
        def latest_offsets(_e, _t), do: {:ok, %{0 => 5}}
      end

      Application.put_env(:shared_infra, :kafka_lag_reader, BrokenReader)

      {_pid, name} = start!()
      log = capture_log(fn -> LagMonitor.poll_now(name) end)

      assert log =~ "[warning]"
      assert log =~ "UNREADABLE"
      assert row(LagMonitor.snapshot(name), group).status == "unknown"
      assert row(LagMonitor.snapshot(name), group).lag == nil
    end
  end
end
