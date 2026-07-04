defmodule ConversationService.Application do
  @moduledoc false

  use Application

  require Logger

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
    # Repo is supervised at boot in dev/prod (so DB-backed requests work); NOT in :test
    # (config sets `start_repo: false`), where DataCase starts it per-test → Docker-free.
    repo =
      if Application.get_env(:conversation_service, :start_repo, true),
        do: [ConversationService.Repo],
        else: []

    client = if kafka_client_needed?(), do: [brod_client_child_spec()], else: []

    # Make the Kafka wiring auditable at boot (same baked-NoopProducer trap the message service hit).
    Logger.info(
      "kafka producer: #{inspect(Application.get_env(:shared_infra, :kafka_producer_adapter))}, " <>
        "brod client #{if client == [], do: "OFF", else: "ON"}"
    )

    repo ++ client ++ http_children()
  end

  # Internal HTTP API listener starts ONLY under CONVERSATION_HTTP_API_ENABLED (default off), so the
  # umbrella boot + plain `mix test` start no listener. Bind on a private network in deployment.
  defp http_children do
    if http_api_enabled?() do
      [
        {Plug.Cowboy,
         scheme: :http, plug: ConversationService.HTTP.Router, options: [port: http_port()]}
      ]
    else
      []
    end
  end

  defp http_api_enabled? do
    Application.get_env(:conversation_service, :http_api_enabled, false) ||
      System.get_env("CONVERSATION_HTTP_API_ENABLED") in ["true", "1", "yes"]
  end

  defp http_port do
    Application.get_env(:conversation_service, :http_port) ||
      String.to_integer(System.get_env("CONVERSATION_HTTP_PORT") || "4102")
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
