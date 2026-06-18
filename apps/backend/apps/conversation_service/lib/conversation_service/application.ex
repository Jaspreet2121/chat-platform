defmodule ConversationService.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(children(),
      strategy: :one_for_one,
      name: ConversationService.Supervisor
    )
  end

  # The brod client starts ONLY when the brod producer adapter is selected AND publishing is
  # enabled (`CONVERSATION_PUBLISH_ENABLED`). With either off (the default) this returns [], so
  # nothing connects at boot and plain `mix test` stays Docker-free. The default producer adapter
  # is the non-connecting NoopProducer, which needs no client at all.
  defp children do
    if kafka_client_needed?(), do: [brod_client_child_spec()], else: []
  end

  defp kafka_client_needed? do
    brod_producer_selected?() and publish_enabled?()
  end

  defp brod_producer_selected? do
    Application.get_env(:shared_infra, :kafka_producer_adapter) ==
      SharedInfra.Kafka.BrodProducer
  end

  defp publish_enabled? do
    Application.get_env(:conversation_service, :conversation_publish_enabled, false) ||
      System.get_env("CONVERSATION_PUBLISH_ENABLED") in ["true", "1", "yes"]
  end

  defp brod_client_child_spec do
    client = ConversationService.ParticipantEvents.client_name()

    endpoints =
      :conversation_service
      |> Application.get_env(:kafka, [])
      |> Keyword.get(:brokers, "localhost:9094")
      |> parse_endpoints()

    %{
      id: client,
      start: {:brod, :start_link_client, [endpoints, client, [auto_start_producers: true]]}
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
