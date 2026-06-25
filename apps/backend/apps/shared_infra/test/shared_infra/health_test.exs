defmodule SharedInfra.HealthTest do
  @moduledoc """
  Plain (Docker-free): the probes are defensive — an unreachable dependency returns a {down, reason}
  status map with latency, never hangs or raises.
  """
  use ExUnit.Case, async: true

  test "tcp probe to an unreachable port returns down with latency + error" do
    result = SharedInfra.Health.tcp("127.0.0.1", 59_999, 300)

    assert result.status == "down"
    assert is_integer(result.latency_ms)
    assert is_binary(result.error)
  end

  test "http_ok to an unreachable url returns down (never raises)" do
    result = SharedInfra.Health.http_ok("http://127.0.0.1:59999/minio/health/ready", 300)

    assert result.status == "down"
    assert is_integer(result.latency_ms)
  end

  test "kafka probe to an unreachable broker returns down" do
    result = SharedInfra.Health.kafka("127.0.0.1:59999", 300)

    assert result.status == "down"
  end
end
