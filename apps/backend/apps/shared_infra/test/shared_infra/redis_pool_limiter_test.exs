defmodule SharedInfra.RedisPoolLimiterTest do
  @moduledoc """
  The rate limiter runs on `SharedInfra.Redis.Pool` — persistent sockets — not a TCP connection per
  check. A fake Redis (a RESP-speaking listener that COUNTS accepted connections) proves it: 20
  checks on a pool of one worker = exactly ONE connection (MUT-7: per-call connections = 20). The
  limits themselves are unchanged: the counter still INCRs, the window still EXPIREs, over the
  limit is still rate_limited with the TTL as retry-after.
  """
  use ExUnit.Case, async: false

  alias SharedInfra.RateLimiter.RedisAdapter

  defmodule FakeRedis do
    @moduledoc false
    # accept loop → one handler process per connection; counters in an Agent.
    def start do
      {:ok, agent} = Agent.start_link(fn -> %{connections: 0, counters: %{}} end)
      {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :line, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)
      spawn_link(fn -> accept(listen, agent) end)
      {port, agent}
    end

    def connections(agent), do: Agent.get(agent, & &1.connections)

    defp accept(listen, agent) do
      case :gen_tcp.accept(listen) do
        {:ok, socket} ->
          Agent.update(agent, &Map.update!(&1, :connections, fn n -> n + 1 end))
          spawn_link(fn -> serve(socket, agent) end)
          accept(listen, agent)

        {:error, _} ->
          :ok
      end
    end

    defp serve(socket, agent) do
      case read_command(socket) do
        {:ok, [cmd | args]} ->
          :gen_tcp.send(socket, reply(String.upcase(cmd), args, agent))
          serve(socket, agent)

        _ ->
          :gen_tcp.close(socket)
      end
    end

    defp read_command(socket) do
      with {:ok, "*" <> n} <- :gen_tcp.recv(socket, 0, 2_000),
           {count, _} <- Integer.parse(String.trim(n)) do
        parts =
          for _ <- 1..count do
            {:ok, "$" <> _len} = :gen_tcp.recv(socket, 0, 2_000)
            {:ok, value} = :gen_tcp.recv(socket, 0, 2_000)
            String.trim_trailing(value, "\r\n")
          end

        {:ok, parts}
      else
        _ -> :error
      end
    end

    defp reply("INCR", [key], agent) do
      n =
        Agent.get_and_update(agent, fn s ->
          n = Map.get(s.counters, key, 0) + 1
          {n, %{s | counters: Map.put(s.counters, key, n)}}
        end)

      ":#{n}\r\n"
    end

    defp reply("EXPIRE", _args, _agent), do: ":1\r\n"
    defp reply("TTL", _args, _agent), do: ":42\r\n"
    defp reply(_cmd, _args, _agent), do: "+OK\r\n"
  end

  setup do
    prev_redis = Application.get_env(:shared_infra, :redis)
    {port, agent} = FakeRedis.start()
    Application.put_env(:shared_infra, :redis, url: "redis://127.0.0.1:#{port}/0", timeout: 1_000)

    # In a full umbrella run the gateway application already runs the pool (size 4); standalone we
    # start one of size 1. Either way every worker drops its socket first, so every connection the
    # fake sees was opened by THIS test's commands.
    unless SharedInfra.Redis.Pool.started?(),
      do: start_supervised!({SharedInfra.Redis.Pool, size: 1})

    :ok = SharedInfra.Redis.Pool.disconnect_all()

    on_exit(fn ->
      if prev_redis,
        do: Application.put_env(:shared_infra, :redis, prev_redis),
        else: Application.delete_env(:shared_infra, :redis)

      if SharedInfra.Redis.Pool.started?(), do: SharedInfra.Redis.Pool.disconnect_all()
    end)

    {:ok, agent: agent}
  end

  defp check(key, limit \\ 100) do
    RedisAdapter.check_rate(%{
      "key" => key,
      "limit" => limit,
      "window_seconds" => 60,
      "now_seconds" => 0,
      "fail_open" => false
    })
  end

  test "MUT-7 guard: 20 checks ride the pool's persistent sockets — one connection per WORKER, never one per check",
       %{agent: agent} do
    size = SharedInfra.Redis.Pool.size()
    assert size in 1..4

    for i <- 1..20, do: assert(:ok = check("pool:#{i}"))
    assert FakeRedis.connections(agent) == size
    assert FakeRedis.connections(agent) < 20
  end

  test "limits are unchanged on the pool: INCR counts, over the limit → rate_limited with the TTL",
       %{agent: agent} do
    for _ <- 1..3, do: assert(:ok = check("same", 3))
    assert {:error, :rate_limited, 42} = check("same", 3)
    assert FakeRedis.connections(agent) <= SharedInfra.Redis.Pool.size()
  end

  test "a worker whose socket died answers one error and reconnects on its next command — never a crash loop" do
    size = SharedInfra.Redis.Pool.size()
    for i <- 1..size, do: assert(:ok = check("warm:#{i}"))

    for {_, worker, _, _} <- Supervisor.which_children(SharedInfra.Redis.Pool) do
      %{socket: socket} = :sys.get_state(worker)
      if is_port(socket), do: :gen_tcp.close(socket)
    end

    # Round-robin: the first `size` commands each meet a dead socket (error, dropped); the next
    # `size` all reconnect.
    results = for i <- 1..(2 * size), do: check("after:#{i}")
    assert Enum.take(results, -size) == List.duplicate(:ok, size)

    assert Enum.all?(Supervisor.which_children(SharedInfra.Redis.Pool), fn {_, w, _, _} ->
             Process.alive?(w)
           end)
  end
end
