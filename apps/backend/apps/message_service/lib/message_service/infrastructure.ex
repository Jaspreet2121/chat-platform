defmodule MessageService.Infrastructure do
  @moduledoc """
  Accessors for message-service infrastructure placeholders.
  """

  def scylla_config do
    SharedInfra.Config.Scylla.from_app(:message_service)
  end

  def kafka_config do
    SharedInfra.Config.Kafka.from_app(:message_service)
  end
end
