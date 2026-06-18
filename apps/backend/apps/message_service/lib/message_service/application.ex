defmodule MessageService.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(children(), strategy: :one_for_one, name: MessageService.Supervisor)
  end

  # The brod Kafka client starts ONLY when the brod producer is selected
  # (`KAFKA_PRODUCER_ADAPTER=brod`) OR the consumer is enabled (`KAFKA_CONSUMER_ENABLED`).
  # The consumer (group subscriber) starts ONLY under `KAFKA_CONSUMER_ENABLED`, after the
  # client. With both flags off (the default) this returns [], so nothing connects at boot
  # and plain `mix test` stays Docker-free.
  defp children do
    client = if kafka_client_needed?(), do: [brod_client_child_spec()], else: []
    consumer = if kafka_consumer_enabled?(), do: [kafka_consumer_child_spec()], else: []
    client ++ consumer
  end

  defp kafka_client_needed?, do: brod_producer_selected?() or kafka_consumer_enabled?()

  defp brod_producer_selected? do
    Application.get_env(:shared_infra, :kafka_producer_adapter) ==
      SharedInfra.Kafka.BrodProducer
  end

  defp kafka_consumer_enabled? do
    Application.get_env(:message_service, :kafka_consumer_enabled, false) ||
      System.get_env("KAFKA_CONSUMER_ENABLED") in ["true", "1", "yes"]
  end

  defp kafka_consumer_child_spec do
    %{
      id: MessageService.Events.MessageCreatedLogConsumer,
      start:
        {:brod, :start_link_group_subscriber_v2,
         [
           %{
             client: SharedInfra.Kafka.BrodProducer.client_name(),
             group_id: "message-service-log-consumer",
             topics: ["message.events.v1"],
             cb_module: MessageService.Events.MessageCreatedLogConsumer,
             consumer_config: [begin_offset: :latest],
             message_type: :message
           }
         ]}
    }
  end

  defp brod_client_child_spec do
    endpoints =
      MessageService.Infrastructure.kafka_config()
      |> Keyword.get(:brokers, "localhost:9094")
      |> parse_endpoints()

    %{
      id: SharedInfra.Kafka.BrodProducer.client_name(),
      start:
        {:brod, :start_link_client,
         [endpoints, SharedInfra.Kafka.BrodProducer.client_name(), [auto_start_producers: true]]}
    }
  end

  defp parse_endpoints(brokers) do
    brokers
    |> String.split(",", trim: true)
    |> Enum.map(fn endpoint ->
      case String.split(endpoint, ":", parts: 2) do
        [host, port] -> {String.to_charlist(host), String.to_integer(port)}
        [host] -> {String.to_charlist(host), 9094}
      end
    end)
  end
end
