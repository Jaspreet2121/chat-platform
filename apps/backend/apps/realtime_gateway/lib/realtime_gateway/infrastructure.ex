defmodule RealtimeGateway.Infrastructure do
  @moduledoc """
  Accessors for realtime-gateway infrastructure placeholders.
  """

  def redis_config do
    SharedInfra.Config.Redis.from_app(:realtime_gateway)
  end

  def kafka_config do
    SharedInfra.Config.Kafka.from_app(:realtime_gateway)
  end
end
