defmodule SharedInfra.ServiceHeartbeatTest do
  @moduledoc """
  The build beacon for services the gateway cannot ping.

  The load-bearing property is that a DEAD process cannot keep itself alive in the console. That is
  the TTL: the key expires on its own, so "the consumer stopped" and "the key is gone" are the same
  event and no sweeper has to notice. A beacon written without an expiry, or a reader that invents a
  value when it cannot read one, would each turn this from evidence into decoration — so both are
  pinned here.
  """
  use ExUnit.Case, async: false

  alias SharedInfra.Redis.Pool
  alias SharedInfra.ServiceHeartbeat

  defmodule FakeRedis do
    @moduledoc "SET/GET/DEL over the wire, recording the TTL each SET carried."

    def start do
      {:ok, agent} = Agent.start_link(fn -> %{store: %{}, ttls: %{}} end)
      {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)
      spawn_link(fn -> accept(listen, agent) end)
      {port, agent}
    end

    def ttl(agent, key), do: Agent.get(agent, &Map.get(&1.ttls, key))
    def put_raw(agent, key, value), do: Agent.update(agent, &put_in(&1.store[key], value))
    def drop(agent, key), do: Agent.update(agent, &%{&1 | store: Map.delete(&1.store, key)})

    defp accept(listen, agent) do
      case :gen_tcp.accept(listen) do
        {:ok, socket} ->
          spawn_link(fn -> serve(socket, agent, "") end)
          accept(listen, agent)

        {:error, _} ->
          :ok
      end
    end

    defp serve(socket, agent, buffer) do
      case read_command(socket, buffer) do
        {:ok, [cmd | args], rest} ->
          :gen_tcp.send(socket, reply(String.upcase(cmd), args, agent))
          serve(socket, agent, rest)

        :error ->
          :gen_tcp.close(socket)
      end
    end

    defp read_command(socket, buffer) do
      case parse_array(buffer) do
        {:ok, parts, rest} ->
          {:ok, parts, rest}

        :incomplete ->
          case :gen_tcp.recv(socket, 0, 2_000) do
            {:ok, data} -> read_command(socket, buffer <> data)
            {:error, _} -> :error
          end
      end
    end

    defp parse_array(<<"*", rest::binary>>) do
      with [count_str, tail] <- :binary.split(rest, "\r\n"),
           {count, ""} <- Integer.parse(count_str) do
        take_bulks(tail, count, [])
      else
        _ -> :incomplete
      end
    end

    defp parse_array(_), do: :incomplete

    defp take_bulks(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

    defp take_bulks(<<"$", rest::binary>>, n, acc) do
      with [len_str, tail] <- :binary.split(rest, "\r\n"),
           {len, ""} <- Integer.parse(len_str),
           <<value::binary-size(^len), "\r\n", tail2::binary>> <- tail do
        take_bulks(tail2, n - 1, [value | acc])
      else
        _ -> :incomplete
      end
    end

    defp take_bulks(_, _, _), do: :incomplete

    defp reply("SET", [key, value | opts], agent) do
      ttl =
        case opts do
          ["EX", seconds | _] -> String.to_integer(seconds)
          _ -> nil
        end

      Agent.update(agent, fn state ->
        %{state | store: Map.put(state.store, key, value), ttls: Map.put(state.ttls, key, ttl)}
      end)

      "+OK\r\n"
    end

    defp reply("GET", [key], agent) do
      case Agent.get(agent, &Map.get(&1.store, key)) do
        nil -> "$-1\r\n"
        value -> "$#{byte_size(value)}\r\n#{value}\r\n"
      end
    end

    defp reply(_cmd, _args, _agent), do: "+OK\r\n"
  end

  setup do
    previous = Application.get_env(:shared_infra, :redis)
    {port, agent} = FakeRedis.start()
    Application.put_env(:shared_infra, :redis, url: "redis://127.0.0.1:#{port}/0", timeout: 1_000)

    # At the umbrella root every app's tests share one BEAM, so the shared Redis pool may still be
    # holding sockets to a PREVIOUS test's listener. Drop them so the first command here connects to
    # this test's fake rather than failing on a closed socket.
    if Pool.started?(), do: Pool.disconnect_all()

    on_exit(fn ->
      if previous,
        do: Application.put_env(:shared_infra, :redis, previous),
        else: Application.delete_env(:shared_infra, :redis)
    end)

    {:ok, agent: agent}
  end

  test "a beat carries the build and an EXPIRY, so a dead process disappears on its own", %{
    agent: agent
  } do
    assert :ok = ServiceHeartbeat.beat("notification", "abc123", 90)

    # The expiry is the whole design. A beacon written WITHOUT one outlives the process that wrote
    # it and reports a stopped consumer as live forever.
    assert FakeRedis.ttl(agent, ServiceHeartbeat.key("notification")) == 90

    assert {:ok, %{git_sha: "abc123", age_seconds: age}} = ServiceHeartbeat.read("notification")
    assert age >= 0
  end

  test "the supervised beacon writes a TTL of three intervals, not one", %{agent: agent} do
    {:ok, pid} = ServiceHeartbeat.start_link(service: "hb-test", interval_ms: 10_000, name: nil)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    key = ServiceHeartbeat.key("hb-test")
    assert eventually(fn -> FakeRedis.ttl(agent, key) != nil end)

    # One interval would expire between beats and flap. Three is "we missed three in a row", which
    # is a real signal rather than a GC pause or a Redis blip.
    assert FakeRedis.ttl(agent, key) == 30
  end

  test "an absent key reads as stale — the same answer as a consumer that stopped", %{
    agent: agent
  } do
    assert :ok = ServiceHeartbeat.beat("notification", "abc123", 90)
    assert {:ok, _} = ServiceHeartbeat.read("notification")

    FakeRedis.drop(agent, ServiceHeartbeat.key("notification"))
    assert ServiceHeartbeat.read("notification") == :stale
  end

  test "an unreadable payload is stale, never an invented build", %{agent: agent} do
    FakeRedis.put_raw(agent, ServiceHeartbeat.key("notification"), "not json at all")
    assert ServiceHeartbeat.read("notification") == :stale

    FakeRedis.put_raw(agent, ServiceHeartbeat.key("notification"), ~s({"git_sha":"x"}))
    # No timestamp means we cannot say how old it is, and a build with no age is not evidence.
    assert ServiceHeartbeat.read("notification") == :stale
  end

  test "an unreachable Redis is stale, not a crash" do
    Application.put_env(:shared_infra, :redis, url: "redis://127.0.0.1:1/0", timeout: 100)
    assert ServiceHeartbeat.read("notification") == :stale
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts <= 0 -> false
      true -> Process.sleep(20) && eventually(fun, attempts - 1)
    end
  end
end
