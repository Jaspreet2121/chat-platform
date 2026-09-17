defmodule SharedInfra.RedisKVPoolTest do
  @moduledoc """
  `SharedInfra.RedisKV` rides `SharedInfra.Redis.Pool` — persistent sockets — instead of opening one
  TCP connection per get/set, and falls back to the one-shot connection on a node that runs no pool
  (only the gateway starts one).

  A fake Redis proves both halves: it COUNTS accepted connections, and it RECORDS every command, so
  the tests can assert the connection count (MUT-7: bypassing the pool makes it 20) and that the key
  shapes and TTLs going over the wire did not change with the move.

  The fake reads commands by BYTE COUNT, not by line, because a Redis value may legally contain
  \\r\\n — the same reason the pool's socket is `packet: :raw`.
  """
  use ExUnit.Case, async: false

  alias SharedInfra.Redis.Pool
  alias SharedInfra.RedisKV

  defmodule FakeRedis do
    @moduledoc false

    def start do
      {:ok, agent} = Agent.start_link(fn -> %{connections: 0, store: %{}, commands: []} end)
      {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)
      spawn_link(fn -> accept(listen, agent) end)
      {port, agent}
    end

    def connections(agent), do: Agent.get(agent, & &1.connections)
    def commands(agent), do: Agent.get(agent, &Enum.reverse(&1.commands))

    defp accept(listen, agent) do
      case :gen_tcp.accept(listen) do
        {:ok, socket} ->
          Agent.update(agent, &Map.update!(&1, :connections, fn n -> n + 1 end))
          spawn_link(fn -> serve(socket, agent, "") end)
          accept(listen, agent)

        {:error, _} ->
          :ok
      end
    end

    defp serve(socket, agent, buffer) do
      case read_command(socket, buffer) do
        {:ok, [cmd | args], rest} ->
          Agent.update(agent, &Map.update!(&1, :commands, fn c -> [[cmd | args] | c] end))
          :gen_tcp.send(socket, reply(String.upcase(cmd), args, agent))
          serve(socket, agent, rest)

        :error ->
          :gen_tcp.close(socket)
      end
    end

    # Byte-counted, so a value containing \r\n survives intact.
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
      previous = Agent.get(agent, &Map.get(&1.store, key))
      Agent.update(agent, &%{&1 | store: Map.put(&1.store, key, value)})
      if "GET" in Enum.map(opts, &String.upcase/1), do: bulk(previous), else: "+OK\r\n"
    end

    defp reply("GET", [key], agent), do: bulk(Agent.get(agent, &Map.get(&1.store, key)))

    defp reply("DEL", [key], agent) do
      hit = Agent.get(agent, &Map.has_key?(&1.store, key))
      Agent.update(agent, &%{&1 | store: Map.delete(&1.store, key)})
      if hit, do: ":1\r\n", else: ":0\r\n"
    end

    # The sorted-set trio is integer-replying, like the limiter's counters.
    defp reply("ZADD", _args, _agent), do: ":1\r\n"
    defp reply("ZREMRANGEBYSCORE", _args, _agent), do: ":0\r\n"
    defp reply("ZCARD", _args, _agent), do: ":7\r\n"
    defp reply("ZREM", _args, _agent), do: ":1\r\n"
    defp reply(_cmd, _args, _agent), do: "+OK\r\n"

    defp bulk(nil), do: "$-1\r\n"
    defp bulk(value), do: "$#{byte_size(value)}\r\n#{value}\r\n"
  end

  setup do
    previous = Application.get_env(:shared_infra, :redis)
    {port, agent} = FakeRedis.start()
    Application.put_env(:shared_infra, :redis, url: "redis://127.0.0.1:#{port}/0", timeout: 1_000)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:shared_infra, :redis, previous),
        else: Application.delete_env(:shared_infra, :redis)
    end)

    {:ok, agent: agent, port: port}
  end

  # A pool of ONE when this run has none. In a full umbrella run another application may already be
  # running one — only the gateway does, and at the umbrella root every app's tests share one BEAM —
  # so take whatever is there and count against ITS size. Every worker drops its socket first, so
  # each connection the fake sees was opened by this test.
  defp with_pool! do
    unless Pool.started?(), do: start_supervised!({Pool, size: 1})
    :ok = Pool.disconnect_all()
    Pool.size()
  end

  # "No pool on this node" without killing anything: UNREGISTER the name. `Pool.started?/0` is
  # `Process.whereis(Pool) != nil`, so this is exactly the condition a service that never starts a
  # pool presents — and because the supervisor is left alive and merely nameless, nothing restarts
  # it behind us and the name goes back afterwards. Stopping it instead would race the parent
  # supervisor's restart. These tests are async: false, so no one else sees the gap.
  defp without_pool! do
    case Process.whereis(Pool) do
      nil ->
        :ok

      pid ->
        Process.unregister(Pool)
        on_exit(fn -> if Process.alive?(pid), do: Process.register(pid, Pool) end)
    end

    refute Pool.started?()
  end

  describe "on the pool" do
    test "MUT-7 guard: 20 gets and sets share ONE socket — a connection per worker, never per call",
         %{agent: agent} do
      size = with_pool!()

      for i <- 1..10 do
        value = "value-#{i}"
        assert :ok = RedisKV.put("kv:#{i}", value, 60)
        assert {:ok, ^value} = RedisKV.get("kv:#{i}")
      end

      # 20 commands, one connection per WORKER. Bypassing the pool makes this 20.
      assert FakeRedis.connections(agent) == size
      assert FakeRedis.connections(agent) < 20
    end

    test "key shapes and TTLs are unchanged by the move: SET key value EX ttl, GET key, DEL key",
         %{agent: agent} do
      with_pool!()

      assert :ok = RedisKV.put("idem:abc", "stored", 90)
      assert {:ok, "stored"} = RedisKV.get("idem:abc")
      assert :ok = RedisKV.del("idem:abc")
      assert :miss = RedisKV.get("idem:abc")

      assert FakeRedis.commands(agent) == [
               ["SET", "idem:abc", "stored", "EX", "90"],
               ["GET", "idem:abc"],
               ["DEL", "idem:abc"],
               ["GET", "idem:abc"]
             ]
    end

    test "an absent key is a MISS, not an error — the pool's $-1 reaches RedisKV as :null" do
      with_pool!()
      assert :miss = RedisKV.get("kv:never-written")
    end

    test "a bulk value containing CRLF round-trips whole — line framing would have cut it in half" do
      with_pool!()
      value = "line one\r\nline two\r\nline three"
      assert :ok = RedisKV.put("kv:crlf", value, 60)
      assert {:ok, ^value} = RedisKV.get("kv:crlf")

      big = String.duplicate("payload-", 5_000)
      assert :ok = RedisKV.put("kv:big", big, 60)
      assert {:ok, ^big} = RedisKV.get("kv:big")
    end

    test "the sorted-set trio rides the pool too — realtime_gateway's connection counter uses it",
         %{agent: agent} do
      size = with_pool!()

      assert :ok = RedisKV.zset_touch("presence:conns:u1", "sock-1", 1_700_000_000, 45)
      assert {:ok, 7} = RedisKV.zset_count("presence:conns:u1", 1_699_999_955)
      assert :ok = RedisKV.zset_remove("presence:conns:u1", "sock-1")

      # Key shapes, scores and the TTL go over the wire exactly as before the move.
      assert FakeRedis.commands(agent) == [
               ["ZADD", "presence:conns:u1", "1700000000", "sock-1"],
               ["EXPIRE", "presence:conns:u1", "45"],
               ["ZREMRANGEBYSCORE", "presence:conns:u1", "-inf", "(1699999955"],
               ["ZCARD", "presence:conns:u1"],
               ["ZREM", "presence:conns:u1", "sock-1"]
             ]

      assert FakeRedis.connections(agent) <= size
    end

    test "put_get still distinguishes absent from present on the pooled socket", %{agent: agent} do
      size = with_pool!()

      assert {:ok, :was_absent} = RedisKV.put_get("presence:u1", "online", 30)
      assert {:ok, {:was_present, "online"}} = RedisKV.put_get("presence:u1", "online", 30)
      assert FakeRedis.connections(agent) <= size
    end
  end

  describe "with no pool on this node" do
    test "MUT-8 guard: calls still succeed on the one-shot connection — a connection per call",
         %{agent: agent} do
      without_pool!()

      for i <- 1..10 do
        value = "value-#{i}"
        assert :ok = RedisKV.put("kv:#{i}", value, 60)
        assert {:ok, ^value} = RedisKV.get("kv:#{i}")
      end

      assert :miss = RedisKV.get("kv:absent")
      # The fall-back path is the OLD behaviour, unchanged: one socket opened and closed per call.
      assert FakeRedis.connections(agent) == 21
    end

    test "the one-shot path speaks the same commands as the pooled one", %{agent: agent} do
      without_pool!()

      assert :ok = RedisKV.put("idem:abc", "stored", 90)
      assert {:ok, "stored"} = RedisKV.get("idem:abc")

      assert FakeRedis.commands(agent) == [
               ["SET", "idem:abc", "stored", "EX", "90"],
               ["GET", "idem:abc"]
             ]
    end
  end
end
