defmodule ApiGatewayWeb.AuthControllerRateLimitTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias SharedInfra.RateLimiter

  setup do
    previous_enabled = Application.get_env(:api_gateway, :rate_limiting_enabled, false)

    previous_adapter =
      Application.get_env(
        :shared_infra,
        :rate_limiter_adapter,
        RateLimiter.RedisQueryPlanAdapter
      )

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

  test "POST /api/v1/auth/otp/request rate limits by client and target" do
    params = %{
      "phone_number" => "+919999999999",
      "purpose" => "login"
    }

    assert 202 == otp_request(params).status
    assert 202 == otp_request(params).status
    assert 202 == otp_request(params).status

    conn = otp_request(params)

    assert conn.status == 429
    assert get_resp_header(conn, "retry-after") == ["60"]

    assert Jason.decode!(conn.resp_body) == %{
             "error" => %{
               "code" => "rate_limit.exceeded",
               "message" => "Too many requests. Please try again later.",
               "correlation_id" => "corr_placeholder"
             }
           }
  end

  defp otp_request(params) do
    :post
    |> conn("/api/v1/auth/otp/request", Jason.encode!(params))
    |> put_req_header("content-type", "application/json")
    |> ApiGatewayWeb.Endpoint.call([])
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
