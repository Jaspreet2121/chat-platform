defmodule ApiGatewayWeb.Plugs.OtpAddressBucketTest do
  @moduledoc """
  THE ADDRESS-ONLY OTP BUCKET (128).

  The existing key is (client address, phone). It bounds how hard one caller can push ONE number and
  bounds nothing at all about how MANY numbers they push — a fresh phone is a fresh key. Since
  possession of a phone number is the only real cost of creating an account, that made account
  creation free at volume, and account creation is where every abuse story in this product starts.

  MUT-10 guard: the address-only bucket absent → RED.

  Docker-free: the plug is driven directly against the in-memory limiter adapter. What is under test
  is WHICH KEYS ARE CHARGED, which is plug logic, not Redis.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.Plugs.RateLimit

  @opts [
    limit: 3,
    window_seconds: 60,
    ip_limit: 30,
    ip_window_seconds: 3600,
    key_prefix: "auth:otp_request",
    fail_open: false
  ]

  setup do
    previous = Application.get_env(:shared_infra, :rate_limiter_adapter)
    previous_enabled = Application.get_env(:api_gateway, :rate_limiting_enabled, false)
    Application.put_env(:api_gateway, :rate_limiting_enabled, true)

    Application.put_env(
      :shared_infra,
      :rate_limiter_adapter,
      SharedInfra.RateLimiter.InMemoryAdapter
    )

    SharedInfra.RateLimiter.InMemoryAdapter.reset()

    on_exit(fn ->
      Application.put_env(:api_gateway, :rate_limiting_enabled, previous_enabled)

      if previous,
        do: Application.put_env(:shared_infra, :rate_limiter_adapter, previous),
        else: Application.delete_env(:shared_infra, :rate_limiter_adapter)
    end)

    :ok
  end

  defp request(phone, address, opts \\ @opts) do
    :post
    |> conn("/api/v1/auth/otp/request", %{"phone_number" => phone})
    |> Map.put(:params, %{"phone_number" => phone})
    |> put_req_header("x-forwarded-for", address)
    |> RateLimit.call(opts)
  end

  # One address, a DIFFERENT number every time — the farm shape. The per-(address, phone) key never
  # repeats, so only the address bucket can possibly refuse this.
  defp burn(n, address, opts \\ @opts) do
    for i <- 1..n, do: request("+1555#{i}", address, opts)
  end

  # THE PLUG HONOURING AN OPTION IS HALF THE GUARD. The other half is the ROUTE actually passing it:
  # the bucket disappears just as completely by being dropped from the pipeline as by being deleted
  # from the plug, and nothing else in the suite would notice. Read from the router source, the way
  # SharedInfra.FormatGateTest reads .formatter.exs, because there is no runtime handle on a
  # pipeline's plug options.
  test "MUT-10 guard: the otp_request pipeline actually CONFIGURES the address-only bucket" do
    router =
      Path.expand("../../../lib/api_gateway_web/router.ex", __DIR__)
      |> File.read!()

    [_, pipeline] = String.split(router, "pipeline :otp_request_rate_limited do", parts: 2)
    [pipeline, _] = String.split(pipeline, "\n  end", parts: 2)

    assert pipeline =~ "ip_limit:",
           "the otp_request pipeline no longer configures an address-only bucket, so one client " <>
             "can burn unlimited phone numbers again: #{pipeline}"

    assert pipeline =~ "ip_window_seconds:"
    assert pipeline =~ "fail_open: false"
  end

  test "MUT-10 guard: 30 distinct numbers from one address pass, the 31st is refused" do
    results = burn(30, "203.0.113.9")
    refute Enum.any?(results, & &1.halted)

    refused = request("+15559999", "203.0.113.9")
    assert refused.halted
    assert refused.status == 429
  end

  test "without the address bucket configured the same burst is unbounded — the hole this closes" do
    narrow_only = Keyword.drop(@opts, [:ip_limit, :ip_window_seconds])

    results = burn(60, "203.0.113.10", narrow_only)
    refute Enum.any?(results, & &1.halted)
  end

  test "the narrow (address, phone) bucket still refuses a burst at ONE number" do
    address = "203.0.113.11"
    for _ <- 1..3, do: refute(request("+15551234", address).halted)

    fourth = request("+15551234", address)
    assert fourth.halted
    assert fourth.status == 429
  end

  test "a DIFFERENT address has its own budget — the bucket is per address, not global" do
    refute Enum.any?(burn(30, "203.0.113.12"), & &1.halted)
    refute request("+15558888", "198.51.100.7").halted
  end

  test "both buckets carry a retry-after so a client backs off rather than hammering" do
    burn(30, "203.0.113.13")
    refused = request("+15559999", "203.0.113.13")

    assert [retry] = get_resp_header(refused, "retry-after")
    assert String.to_integer(retry) > 0
  end
end
