defmodule MessageService.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(children(), strategy: :one_for_one, name: MessageService.Supervisor)
  end

  # The brod Kafka client is started ONLY when the brod-backed producer adapter is
  # selected (`KAFKA_PRODUCER_ADAPTER=brod`). With the default `NoopProducer` this
  # returns [], so nothing connects at boot and plain `mix test` stays Docker-free.
  defp children do
    if brod_producer_selected?() do
      [brod_client_child_spec()]
    else
      []
    end
  end

  defp brod_producer_selected? do
    Application.get_env(:shared_infra, :kafka_producer_adapter) ==
      SharedInfra.Kafka.BrodProducer
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
