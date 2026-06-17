defmodule SharedInfra.RateLimiterTest do
  use ExUnit.Case, async: false

  alias SharedInfra.RateLimiter

  setup do
    previous_adapter =
      Application.get_env(
        :shared_infra,
        :rate_limiter_adapter,
        RateLimiter.RedisAdapter
      )

    previous_fail_open = Application.get_env(:shared_infra, :rate_limiter_fail_open, true)
    previous_redis_config = Application.get_env(:shared_infra, :redis, [])

    Application.put_env(:shared_infra, :rate_limiter_adapter, RateLimiter.InMemoryAdapter)

    start_in_memory_adapter!()
    RateLimiter.InMemoryAdapter.reset()

    on_exit(fn ->
      RateLimiter.InMemoryAdapter.reset()
      Application.put_env(:shared_infra, :rate_limiter_adapter, previous_adapter)
      Application.put_env(:shared_infra, :rate_limiter_fail_open, previous_fail_open)
      Application.put_env(:shared_infra, :redis, previous_redis_config)
    end)

    :ok
  end

  test "under limit returns ok" do
    attrs = %{
      "key" => "auth:otp_request:127.0.0.1:+15551234567",
      "limit" => 2,
      "window_seconds" => 60,
      "now_seconds" => 100
    }

    assert :ok = RateLimiter.check_rate(attrs)
    assert :ok = RateLimiter.check_rate(attrs)
  end

  test "over limit returns retry_after_seconds" do
    attrs = %{
      "key" => "auth:otp_request:127.0.0.1:+15551234567",
      "limit" => 1,
      "window_seconds" => 60,
      "now_seconds" => 100
    }

    assert :ok = RateLimiter.check_rate(attrs)
    assert {:error, :rate_limited, 60} = RateLimiter.check_rate(attrs)
  end

  test "window expiration resets counter" do
    key = "auth:otp_request:127.0.0.1:+15551234567"

    assert :ok =
             RateLimiter.check_rate(%{
               "key" => key,
               "limit" => 1,
               "window_seconds" => 1,
               "now_seconds" => 100
             })

    assert {:error, :rate_limited, 1} =
             RateLimiter.check_rate(%{
               "key" => key,
               "limit" => 1,
               "window_seconds" => 1,
               "now_seconds" => 100
             })

    assert :ok =
             RateLimiter.check_rate(%{
               "key" => key,
               "limit" => 1,
               "window_seconds" => 1,
               "now_seconds" => 101
             })
  end

  test "redis query-plan adapter documents live Redis as unavailable" do
    Application.put_env(:shared_infra, :rate_limiter_adapter, RateLimiter.RedisQueryPlanAdapter)

    assert {:error, :rate_limiter_unavailable, plan} =
             RateLimiter.check_rate(%{
               "key" => "auth:otp_request:127.0.0.1:+15551234567",
               "limit" => 1,
               "window_seconds" => 60,
               "now_seconds" => 100
             })

    assert [["INCR", key], ["EXPIRE", expire_key, 60]] = plan
    assert expire_key == key
  end

  test "redis adapter fails open when configured and Redis is unavailable" do
    Application.put_env(:shared_infra, :rate_limiter_adapter, RateLimiter.RedisAdapter)
    Application.put_env(:shared_infra, :rate_limiter_fail_open, true)
    Application.put_env(:shared_infra, :redis, url: "redis://127.0.0.1:1/0")

    assert :ok =
             RateLimiter.check_rate(%{
               "key" => "auth:otp_request:127.0.0.1:+15551234567",
               "limit" => 1,
               "window_seconds" => 60
             })
  end

  test "redis adapter reports unavailable when fail-open is disabled" do
    Application.put_env(:shared_infra, :rate_limiter_adapter, RateLimiter.RedisAdapter)
    Application.put_env(:shared_infra, :rate_limiter_fail_open, false)
    Application.put_env(:shared_infra, :redis, url: "redis://127.0.0.1:1/0")

    assert {:error, :rate_limiter_unavailable, _reason} =
             RateLimiter.check_rate(%{
               "key" => "auth:otp_request:127.0.0.1:+15551234567",
               "limit" => 1,
               "window_seconds" => 60
             })
  end

  @tag :redis_integration
  test "redis adapter limits repeated calls against live Redis" do
    redis_url = System.get_env("RATE_LIMITER_REDIS_URL") || "redis://localhost:6379/0"

    Application.put_env(:shared_infra, :rate_limiter_adapter, RateLimiter.RedisAdapter)
    Application.put_env(:shared_infra, :rate_limiter_fail_open, false)
    Application.put_env(:shared_infra, :redis, url: redis_url)

    key = "auth:otp_request:redis_integration:#{System.unique_integer([:positive])}"

    attrs = %{
      "key" => key,
      "limit" => 1,
      "window_seconds" => 60
    }

    assert :ok = RateLimiter.check_rate(attrs)
    assert {:error, :rate_limited, retry_after_seconds} = RateLimiter.check_rate(attrs)
    assert retry_after_seconds > 0
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
