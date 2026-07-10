defmodule RealtimeGateway.LimitsTest.DownRateLimiter do
  @moduledoc "A rate-limiter adapter that always reports unavailable — to prove the socket path fails OPEN."
  @behaviour SharedInfra.RateLimiter

  @impl true
  def check_rate(_attrs), do: {:error, :rate_limiter_unavailable, :test_down}
end

defmodule RealtimeGateway.LimitsTest do
  @moduledoc """
  Connection cap + per-bucket (join / write / ephemeral) rate limits on /socket. Docker-free: the connection
  counter uses in-process ETS and the rate limiter uses the in-memory adapter, so every assertion is real
  (no mocked increment/decrement) and deterministic. Unique per-test user/app ids keep the shared ETS +
  rate-limiter state from bleeding between tests.
  """
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  alias RealtimeGateway.ConnectionCounter
  alias RealtimeGateway.Limits

  @endpoint RealtimeGateway.TestEndpoint

  @env_keys ~w(RT_JOIN_LIMIT RT_WRITE_LIMIT RT_EPHEMERAL_LIMIT RT_MAX_SOCKETS_PER_USER
               RT_MAX_SOCKETS_PER_APP RT_APP_LIMIT_FACTOR RT_CONN_TTL_SECONDS RT_RUNTIME_BACKEND)

  setup do
    saved_env = Map.new(@env_keys, fn k -> {k, System.get_env(k)} end)
    prev_backend = Application.get_env(:realtime_gateway, :connection_counter_backend)
    prev_adapter = Application.get_env(:shared_infra, :rate_limiter_adapter)
    prev_redis = Application.get_env(:shared_infra, :redis)
    prev_socket_auth = Application.get_env(:realtime_gateway, :socket_auth_persistence, false)

    # Deterministic baseline: ETS counter, in-memory rate limiter (freshly reset), placeholder socket auth.
    Application.put_env(:realtime_gateway, :connection_counter_backend, :ets)
    Application.put_env(:realtime_gateway, :socket_auth_persistence, false)
    SharedInfra.RateLimiter.InMemoryAdapter.reset()

    on_exit(fn ->
      Enum.each(saved_env, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      Application.put_env(:realtime_gateway, :connection_counter_backend, prev_backend)
      Application.put_env(:realtime_gateway, :socket_auth_persistence, prev_socket_auth)
      if prev_adapter, do: Application.put_env(:shared_infra, :rate_limiter_adapter, prev_adapter)
      if prev_redis, do: Application.put_env(:shared_infra, :redis, prev_redis)
    end)

    :ok
  end

  # --- ConnectionCounter (the leak-proof primitive) ---------------------------------------------------

  test "count/touch/remove reflect live membership on real ETS" do
    key = uniq("rt:conn:user")
    now = now()

    assert ConnectionCounter.count(key, now) == 0
    ConnectionCounter.touch(key, "sock_a", now)
    ConnectionCounter.touch(key, "sock_b", now)
    assert ConnectionCounter.count(key, now) == 2

    ConnectionCounter.remove(key, "sock_a")
    assert ConnectionCounter.count(key, now) == 1
  end

  test "a crashed socket that never decremented ages out of the count once its TTL passes" do
    key = uniq("rt:conn:user")
    t0 = now()
    ttl = ConnectionCounter.ttl_seconds()

    ConnectionCounter.touch(key, "dead_sock", t0)
    # Still counted within the window...
    assert ConnectionCounter.count(key, t0 + ttl - 1) == 1
    # ...and reclaimed once its last-seen score falls outside the window — no permanent leak, no lockout.
    assert ConnectionCounter.count(key, t0 + ttl + 1) == 0
  end

  # --- connection cap (via Limits, real ETS) ----------------------------------------------------------

  test "admits under the per-user cap and refuses at it" do
    System.put_env("RT_MAX_SOCKETS_PER_USER", "3")
    user = uniq("user")
    app = uniq("app")

    for _ <- 1..3, do: assert({:ok, _ref} = Limits.check_connection(sock(user, app)))
    assert Limits.check_connection(sock(user, app)) == :error
  end

  test "disconnect decrements so a reconnect succeeds (catches a leaking counter — real decrement)" do
    System.put_env("RT_MAX_SOCKETS_PER_USER", "3")
    user = uniq("user")
    app = uniq("app")

    refs =
      for _ <- 1..3 do
        assert {:ok, ref} = Limits.check_connection(sock(user, app))
        ref
      end

    # At the cap.
    assert Limits.check_connection(sock(user, app)) == :error

    # A clean disconnect releases one slot (the immediate decrement path)...
    [freed | _] = refs
    assert :ok = Limits.release_connection(user, app, freed)

    # ...and the freed slot is immediately reusable.
    assert {:ok, _new_ref} = Limits.check_connection(sock(user, app))
  end

  test "the per-app cap trips independently of the per-user cap" do
    System.put_env("RT_MAX_SOCKETS_PER_APP", "3")
    app = uniq("app")

    # Three DISTINCT users, each well under their own (unlimited) cap, fill the tenant cap.
    for i <- 1..3, do: assert({:ok, _} = Limits.check_connection(sock("#{app}_u#{i}", app)))
    # A fourth distinct user is refused purely on the per-app ceiling.
    assert Limits.check_connection(sock("#{app}_u4", app)) == :error
    # A different tenant is unaffected.
    assert {:ok, _} = Limits.check_connection(sock("other_u", uniq("app")))
  end

  test "a test-twin app_id is capped separately from the live parent app" do
    System.put_env("RT_MAX_SOCKETS_PER_APP", "2")
    app_live = uniq("app_live")
    app_test = uniq("app_test")
    refute app_live == app_test

    assert {:ok, _} = Limits.check_connection(sock("u1", app_live))
    assert {:ok, _} = Limits.check_connection(sock("u2", app_live))
    # Live app is at its cap...
    assert Limits.check_connection(sock("u3", app_live)) == :error
    # ...but the distinct test twin has its own count and still admits.
    assert {:ok, _} = Limits.check_connection(sock("u1", app_test))
    assert {:ok, _} = Limits.check_connection(sock("u2", app_test))
    assert Limits.check_connection(sock("u3", app_test)) == :error
  end

  # --- rate buckets (via Limits, in-memory rate limiter) ----------------------------------------------

  test "write over the limit → error reply with retry_after, socket stays alive, recovers after the window" do
    System.put_env("RT_WRITE_LIMIT", "2")
    s = sock(uniq("user"), uniq("app"))

    assert Limits.check_write(s) == :ok
    assert Limits.check_write(s) == :ok

    assert {:reply, {:error, %{reason: "rate_limited", retry_after: retry_after}}, ^s} =
             Limits.check_write(s)

    assert is_integer(retry_after) and retry_after >= 1

    # The window rolling over (modelled by resetting the fixed-window counter) lets the same socket send again.
    SharedInfra.RateLimiter.InMemoryAdapter.reset()
    assert Limits.check_write(s) == :ok
  end

  test "ephemeral over the limit → dropped silently ({:noreply}), no error reply" do
    System.put_env("RT_EPHEMERAL_LIMIT", "1")
    s = sock(uniq("user"), uniq("app"))

    assert Limits.check_ephemeral(s) == :ok
    assert Limits.check_ephemeral(s) == {:noreply, s}
  end

  test "join over the limit → refused with rate_limited" do
    System.put_env("RT_JOIN_LIMIT", "1")
    s = sock(uniq("user"), uniq("app"))

    assert Limits.check_join(s) == :ok
    assert Limits.check_join(s) == {:error, %{reason: "rate_limited"}}
  end

  test "the per-app write ceiling trips even while each user is under their own limit" do
    # factor 1 makes per-app == per-user (3) so two users together overflow the tenant before either
    # overflows individually — proving the app scope is checked independently of the user scope.
    System.put_env("RT_WRITE_LIMIT", "3")
    System.put_env("RT_APP_LIMIT_FACTOR", "1")
    app = uniq("app")
    u1 = sock(uniq("user"), app)
    u2 = sock(uniq("user"), app)

    assert Limits.check_write(u1) == :ok
    assert Limits.check_write(u1) == :ok
    assert Limits.check_write(u2) == :ok
    # u2's own count is only 2 (< 3), but the app is now at 4 (> 3) → refused on the app scope.
    assert {:reply, {:error, %{reason: "rate_limited"}}, ^u2} = Limits.check_write(u2)
  end

  # --- fail-open ---------------------------------------------------------------------------------------

  test "every rate bucket fails OPEN when the rate limiter is unavailable" do
    Application.put_env(:shared_infra, :rate_limiter_adapter, RealtimeGateway.LimitsTest.DownRateLimiter)
    # Even with the limits set to 1, an unavailable limiter must ALLOW (never take the socket down).
    System.put_env("RT_JOIN_LIMIT", "1")
    System.put_env("RT_WRITE_LIMIT", "1")
    System.put_env("RT_EPHEMERAL_LIMIT", "1")
    s = sock(uniq("user"), uniq("app"))

    for _ <- 1..5 do
      assert Limits.check_join(s) == :ok
      assert Limits.check_write(s) == :ok
      assert Limits.check_ephemeral(s) == :ok
    end
  end

  test "the connection cap fails OPEN when Redis is unreachable" do
    # Point the counter at Redis with a dead address so every ZSET call errors.
    Application.put_env(:realtime_gateway, :connection_counter_backend, :redis)
    Application.put_env(:shared_infra, :redis, url: "redis://127.0.0.1:6390/0", timeout: 200)
    System.put_env("RT_MAX_SOCKETS_PER_USER", "1")
    key = uniq("rt:conn:user")

    # count → 0 (fail-open) and touch → :ok (no crash), so a new connection is always admitted.
    assert ConnectionCounter.count(key, now()) == 0
    assert ConnectionCounter.touch(key, "sock", now()) == :ok
    assert {:ok, _ref} = Limits.check_connection(sock(uniq("user"), uniq("app")))
  end

  # --- integration wiring (real connect/3 + user channel terminate) -----------------------------------

  test "connect/3 admits under the cap, assigns a socket_ref, and refuses over the per-user cap" do
    System.put_env("RT_MAX_SOCKETS_PER_USER", "2")
    user = uniq("user")

    assert {:ok, s1} = connect(RealtimeGateway.UserSocket, %{"user_id" => user})
    assert is_binary(s1.assigns.socket_ref)
    assert {:ok, _s2} = connect(RealtimeGateway.UserSocket, %{"user_id" => user})
    assert {:error, %{reason: "connection_limit"}} =
             connect(RealtimeGateway.UserSocket, %{"user_id" => user})
  end

  test "the user channel releases the connection slot on terminate (no leak on disconnect)" do
    user = uniq("user")
    app = uniq("app")
    ref = uniq("sockref")
    key = "rt:conn:user:#{user}"

    {:ok, _join, socket} =
      RealtimeGateway.UserSocket
      |> socket("user_socket:#{user}", %{
        current_user_id: user,
        user_id: user,
        app_id: app,
        socket_ref: ref
      })
      |> subscribe_and_join(RealtimeGateway.UserChannel, "user:#{user}", %{})

    # Joining the user channel seeded this socket's slot in the counter.
    assert ConnectionCounter.count(key, now()) == 1

    # A real disconnect: leave the channel (unlink first so this test process survives the shutdown), then
    # wait for the channel process to actually terminate before confirming its slot was released.
    pid = socket.channel_pid
    Process.unlink(pid)
    monitor = Process.monitor(pid)
    ref = leave(socket)
    assert_reply ref, :ok
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 1000

    assert ConnectionCounter.count(key, now()) == 0
  end

  # --- helpers ----------------------------------------------------------------------------------------

  defp sock(user_id, app_id) do
    %{assigns: %{user_id: user_id, current_user_id: user_id, app_id: app_id}}
  end

  defp uniq(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp now, do: System.system_time(:second)
end
