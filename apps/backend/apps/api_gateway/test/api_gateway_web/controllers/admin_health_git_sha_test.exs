defmodule ApiGatewayWeb.AdminHealthGitShaTest do
  @moduledoc """
  /admin/health carries EVERY service's own git_sha, read from that service's /internal/health body
  — "unknown" when the service is down or its body has no such field (an image from before the
  field existed must not crash the aggregate). The rest of the response is exactly what it was.
  Two services answer from a real localhost listener: one with a sha, one without.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  @port 4198
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

  # Two fake services on one listener, told apart by base-url path prefix.
  defmodule FakeServices do
    @moduledoc false
    use Plug.Router
    plug(:match)
    plug(:dispatch)

    get "/withsha/internal/health" do
      reply(conn, %{service: "auth", status: "ok", deps: %{}, git_sha: "abc1234"})
    end

    get "/nosha/internal/health" do
      reply(conn, %{service: "user", status: "ok", deps: %{}})
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

  setup do
    # ISOLATE FROM ANY REACHABLE REDIS. The notification row is expected "stale" because nothing is
    # beating — but the test env's Redis URL is localhost:6379, and a local prod-shaped stack running
    # on this machine has a REAL notification container beating there. Point the read at a closed
    # port for the duration and drop pooled sockets, so the answer is decided by this test alone.
    previous_redis = Application.get_env(:shared_infra, :redis)
    Application.put_env(:shared_infra, :redis, url: "redis://127.0.0.1:1/0", timeout: 100)
    if SharedInfra.Redis.Pool.started?(), do: SharedInfra.Redis.Pool.disconnect_all()

    on_exit(fn ->
      if previous_redis,
        do: Application.put_env(:shared_infra, :redis, previous_redis),
        else: Application.delete_env(:shared_infra, :redis)

      if SharedInfra.Redis.Pool.started?(), do: SharedInfra.Redis.Pool.disconnect_all()
    end)

    keys = [
      {:shared_infra, :auth_client_adapter},
      {:shared_infra, :auth_service_url},
      {:shared_infra, :user_service_url},
      {:shared_infra, :conversation_service_url},
      {:shared_infra, :message_service_url},
      {:shared_infra, :media_service_url}
    ]

    prev = for {app, key} <- keys, into: %{}, do: {{app, key}, Application.get_env(app, key)}

    start_supervised!({Plug.Cowboy, scheme: :http, plug: FakeServices, options: [port: @port]})

    Application.put_env(:shared_infra, :auth_client_adapter, AdminStub)
    Application.put_env(:shared_infra, :auth_service_url, "http://localhost:#{@port}/withsha")
    Application.put_env(:shared_infra, :user_service_url, "http://localhost:#{@port}/nosha")
    # Unset → unreachable without a network attempt (no env fallback in test).
    for key <- [:conversation_service_url, :message_service_url, :media_service_url],
        do: Application.delete_env(:shared_infra, key)

    on_exit(fn ->
      for {{app, key}, value} <- prev do
        if value == nil,
          do: Application.delete_env(app, key),
          else: Application.put_env(app, key, value)
      end
    end)

    :ok
  end

  test "each services[] entry carries that service's git_sha; down or absent → \"unknown\"; shape otherwise unchanged" do
    conn =
      conn(:get, "/api/v1/admin/health")
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer x")
      |> ApiGatewayWeb.Router.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    # KEY-SET: top level. `consumer_lag` joined it with the lag alarm — one curl on this endpoint is
    # meant to answer "is anything behind?", which it cannot do if the numbers are not in the body.
    assert Map.keys(body) |> Enum.sort() == [
             "checked_at",
             "consumer_lag",
             "dependencies",
             "git_sha",
             "services",
             "status"
           ]

    assert body["git_sha"] == SharedInfra.BuildInfo.git_sha()

    by_name = Map.new(body["services"], &{&1["name"], &1})

    assert Map.keys(by_name) |> Enum.sort() == [
             "auth",
             "conversation",
             "media",
             "message",
             "notification",
             "realtime",
             "user"
           ]

    # Every pinged service reports exactly name/status/git_sha. notification is the exception and
    # carries the age of its heartbeat too — it is the one service nothing here can ping.
    for {name, entry} <- by_name,
        name != "notification",
        do: assert(Map.keys(entry) |> Enum.sort() == ["git_sha", "name", "status"])

    # Reachable WITH the field → its own sha.
    assert by_name["auth"] == %{"name" => "auth", "status" => "up", "git_sha" => "abc1234"}
    # Reachable WITHOUT the field (older image) → up, unknown — never a crash (MUT-6).
    assert by_name["user"] == %{"name" => "user", "status" => "up", "git_sha" => "unknown"}
    # Down → unknown.
    assert by_name["conversation"] == %{
             "name" => "conversation",
             "status" => "down",
             "git_sha" => "unknown"
           }

    assert by_name["message"]["git_sha"] == "unknown"
    assert by_name["media"]["git_sha"] == "unknown"
    # In-process / no endpoint: as today for status, with the sha we can vouch for.
    assert by_name["realtime"] == %{
             "name" => "realtime",
             "status" => "up",
             "git_sha" => SharedInfra.BuildInfo.git_sha()
           }

    # No heartbeat in Redis (none is running in this test) → stale, which is what "nobody can vouch
    # for that process right now" looks like. Never "up", and deliberately never "down" either.
    assert by_name["notification"] == %{
             "name" => "notification",
             "status" => "stale",
             "git_sha" => "unknown",
             "heartbeat_age_seconds" => nil
           }
  end
end
