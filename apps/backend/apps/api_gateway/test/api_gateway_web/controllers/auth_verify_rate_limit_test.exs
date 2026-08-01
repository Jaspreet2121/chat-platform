defmodule ApiGatewayWeb.AuthVerifyRateLimitTest do
  @moduledoc """
  THE OUTER BOUND ON OTP BRUTE FORCE — the per-(IP, phone) limit on `POST /auth/otp/verify`.

  The per-otp_request_id attempts cap (AuthService.OTP, 5) is the primary defence, but on its own it
  is trivially bypassed: request a FRESH id and you get another 5 guesses, forever. This limit is
  what makes that bypass expensive, so the two compose rather than one making the other pointless.

  Also proves the things the audit found were NOT true of this plug before: that it fails CLOSED (a
  limiter outage must not reopen the takeover path), and that its per-IP key survives the reverse
  proxy — `conn.remote_ip` is Caddy's bridge address for every caller in production, which had
  silently collapsed the IP component to a constant.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias SharedInfra.RateLimiter

  # Must match the :otp_verify_rate_limited pipeline in the router.
  @limit 20
  @window 300

  setup do
    previous_enabled = Application.get_env(:api_gateway, :rate_limiting_enabled, false)

    previous_adapter =
      Application.get_env(:shared_infra, :rate_limiter_adapter, RateLimiter.RedisQueryPlanAdapter)

    Application.put_env(:api_gateway, :rate_limiting_enabled, true)
    Application.put_env(:shared_infra, :rate_limiter_adapter, RateLimiter.InMemoryAdapter)

    start_in_memory_adapter!()
    RateLimiter.InMemoryAdapter.reset()

    on_exit(fn ->
      RateLimiter.InMemoryAdapter.reset()
      Application.put_env(:api_gateway, :rate_limiting_enabled, previous_enabled)
      Application.put_env(:shared_infra, :rate_limiter_adapter, previous_adapter)
    end)

    :ok
  end

  test "a legitimate burst below the limit is never throttled" do
    # Four codes' worth of a user fumbling every digit. Nobody typing a code they were sent gets here.
    for n <- 1..@limit do
      refute verify("+15550001111").status == 429, "attempt #{n} should not be rate limited"
    end
  end

  test "over the limit → 429 with Retry-After, and the uniform error envelope" do
    for _ <- 1..@limit, do: verify("+15550002222")

    conn = verify("+15550002222")

    assert conn.status == 429
    assert get_resp_header(conn, "retry-after") == [Integer.to_string(@window)]

    assert %{"error" => %{"code" => "rate_limit.exceeded", "correlation_id" => correlation_id}} =
             Jason.decode!(conn.resp_body)

    assert is_binary(correlation_id) and correlation_id != ""
  end

  test "SCOPING: one target's traffic never consumes another's budget" do
    for _ <- 1..(@limit + 1), do: verify("+15550003333")
    assert verify("+15550003333").status == 429

    # A different phone has an untouched budget. Without this, one attacker could lock every user in
    # the system out of logging in — a denial of service built out of the anti-brute-force control.
    refute verify("+15550004444").status == 429
  end

  test "SCOPING: the key follows the FORWARDED client IP, not the proxy's" do
    # Every request arrives from Caddy, so remote_ip is identical for all callers. If the key used it,
    # these two distinct clients would share one budget.
    for _ <- 1..(@limit + 1), do: verify("+15550005555", forwarded_for: "203.0.113.7")
    assert verify("+15550005555", forwarded_for: "203.0.113.7").status == 429

    refute verify("+15550005555", forwarded_for: "203.0.113.8").status == 429
  end

  test "SPOOF RESISTANCE: a client-supplied X-Forwarded-For cannot mint a fresh budget" do
    # Caddy APPENDS the address it observed, so the rightmost entry is the one the client cannot
    # forge. Taking the leftmost would let an attacker rotate the header and bypass the limit
    # entirely — these two requests must land in the SAME bucket because the real peer is the same.
    for _ <- 1..(@limit + 1),
        do: verify("+15550006666", forwarded_for: "1.1.1.1, 198.51.100.4")

    assert verify("+15550006666", forwarded_for: "9.9.9.9, 198.51.100.4").status == 429
  end

  test "FAIL-CLOSED: a limiter outage rejects with 503, it does not open the gate" do
    # This limiter IS the security control. Failing open here would restore the unbounded brute-force
    # path exactly when the limiter is least able to observe it.
    Application.put_env(:shared_infra, :rate_limiter_adapter, RateLimiter.RedisQueryPlanAdapter)

    conn = verify("+15550007777")

    assert conn.status == 503
    assert get_resp_header(conn, "retry-after") == ["30"]
    assert %{"error" => %{"code" => "auth.limiter_unavailable"}} = Jason.decode!(conn.resp_body)
  end

  defp verify(phone, opts \\ []) do
    conn =
      :post
      |> conn(
        "/api/v1/auth/otp/verify",
        Jason.encode!(%{
          "otp_request_id" => Ecto.UUID.generate(),
          "phone_number" => phone,
          "otp_code" => "000000",
          "device_id" => "d1"
        })
      )
      |> put_req_header("content-type", "application/json")

    conn =
      case Keyword.get(opts, :forwarded_for) do
        nil -> conn
        value -> put_req_header(conn, "x-forwarded-for", value)
      end

    ApiGatewayWeb.Endpoint.call(conn, [])
  end

  defp start_in_memory_adapter! do
    case RateLimiter.InMemoryAdapter.start_link() do
      {:ok, pid} ->
        Process.unlink(pid)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end
end
