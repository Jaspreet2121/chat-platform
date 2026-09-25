defmodule ApiGatewayWeb.AdminHealthNotificationHeartbeatTest do
  @moduledoc """
  notification-service has no inbound port, so /admin/health cannot ping it. It reads that service's
  HEARTBEAT instead — a Redis key with a TTL that only a running consumer refreshes.

  Two states, and the difference between them is the entire point of the feature: a fresh beat means
  the consumer is up AND tells us which build it is running (the one place a stale image is hardest
  to notice, because pushes simply stop arriving). No beat means stale — and a stale push consumer
  DEGRADES the platform, because "healthy" while notifications may not be delivering is exactly the
  answer this replaced.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias SharedInfra.Redis.Pool
  alias SharedInfra.ServiceHeartbeat

  @port 4199
  @opts ApiGatewayWeb.Router.init([])

  defmodule AdminStub do
    @moduledoc false
    def current_session(_attrs),
      do:
        {:ok,
         %{
           user_id: "admin",
           session_id: "s",
           device_id: "d",
           platform: "web",
           is_admin: true,
           role: "admin"
         }}

    def persistence_enabled?, do: true
  end

  defmodule FakeServices do
    @moduledoc false
    use Plug.Router
    plug(:match)
    plug(:dispatch)

    # message and media own the platform dependencies the aggregator reports, so both must answer
    # HEALTHY here — otherwise the overall rollup is pinned at "degraded" by the harness and cannot
    # show whether the notification heartbeat moved it.
    get "/message/internal/health" do
      reply(conn, %{
        service: "message",
        status: "ok",
        git_sha: "abc1234",
        deps: %{postgres: %{status: "up"}, kafka: %{status: "up"}},
        consumer_lag: %{status: "ok", stale: false, groups: []}
      })
    end

    get "/media/internal/health" do
      reply(conn, %{
        service: "media",
        status: "ok",
        git_sha: "abc1234",
        deps: %{minio: %{status: "up"}}
      })
    end

    get "/:service/internal/health" do
      reply(conn, %{service: service, status: "ok", deps: %{}, git_sha: "abc1234"})
    end

    match _ do
      send_resp(conn, 404, "{}")
    end

    defp reply(conn, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"ok" => body}))
    end
  end

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
    keys = [
      {:shared_infra, :auth_client_adapter},
      {:shared_infra, :auth_service_url},
      {:shared_infra, :user_service_url},
      {:shared_infra, :conversation_service_url},
      {:shared_infra, :message_service_url},
      {:shared_infra, :media_service_url},
      {:shared_infra, :redis}
    ]

    prev = for {app, key} <- keys, into: %{}, do: {{app, key}, Application.get_env(app, key)}

    start_supervised!({Plug.Cowboy, scheme: :http, plug: FakeServices, options: [port: @port]})
    {redis_port, agent} = FakeRedis.start()

    Application.put_env(:shared_infra, :auth_client_adapter, AdminStub)

    for {key, path} <- [
          auth_service_url: "auth",
          user_service_url: "user",
          conversation_service_url: "conversation",
          message_service_url: "message",
          media_service_url: "media"
        ],
        do: Application.put_env(:shared_infra, key, "http://localhost:#{@port}/#{path}")

    Application.put_env(:shared_infra, :redis,
      url: "redis://127.0.0.1:#{redis_port}/0",
      timeout: 1_000
    )

    # The umbrella root shares one BEAM: drop pooled sockets pointing at an earlier test's listener.
    if Pool.started?(), do: Pool.disconnect_all()

    on_exit(fn ->
      for {{app, key}, value} <- prev do
        if value == nil,
          do: Application.delete_env(app, key),
          else: Application.put_env(app, key, value)
      end
    end)

    {:ok, agent: agent}
  end

  defp health do
    conn =
      conn(:get, "/api/v1/admin/health")
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer x")
      |> ApiGatewayWeb.Router.call(@opts)

    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  defp notification(body), do: Enum.find(body["services"], &(&1["name"] == "notification"))

  test "a fresh beat reports the consumer up, on ITS OWN build" do
    assert :ok = ServiceHeartbeat.beat("notification", "deadbee", 90)

    entry = notification(health())
    assert entry["status"] == "up"
    # The build comes from the CONSUMER, not from the gateway. A gateway that substituted its own
    # here would show every deploy as complete the moment the gateway restarted.
    assert entry["git_sha"] == "deadbee"
    refute entry["git_sha"] == SharedInfra.BuildInfo.git_sha()
    assert is_integer(entry["heartbeat_age_seconds"])
  end

  test "no beat means stale, and stale degrades the platform", %{agent: agent} do
    assert :ok = ServiceHeartbeat.beat("notification", "deadbee", 90)
    assert notification(health())["status"] == "up"

    # The key expiring IS the consumer stopping, as far as anything here can tell.
    FakeRedis.drop(agent, ServiceHeartbeat.key("notification"))

    body = health()
    assert notification(body)["status"] == "stale"
    assert notification(body)["git_sha"] == "unknown"

    # THE ROLLUP MOVES. Every dependency and every other service in this harness is up, so the
    # notification heartbeat is the only thing that can change this field — which is the point:
    # "healthy" while pushes may not be delivering is the answer this whole feature replaced.
    assert body["status"] == "degraded"
  end
end
