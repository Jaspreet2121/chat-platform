defmodule NotificationService.Application do
  @moduledoc false

  use Application

  @client :notification_service_kafka_client
  @topic "message.events.v1"
  @group "notification-service-message-created"

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(children(), strategy: :one_for_one, name: NotificationService.Supervisor)
  end

  # NOTHING starts unless NOTIFICATION_CONSUMER_ENABLED. When enabled we start the Repo,
  # the brod client, and the consumer TOGETHER, so the consumer can actually persist in
  # dev/prod. The Repo is NOT supervised unconditionally — with the flag off (the default)
  # this returns [], so nothing connects at boot and plain `mix test` stays Docker-free.
  # The Repo-only postgres_integration test starts its own Repo via DataCase, independent
  # of this flag.
  defp children do
    if consumer_enabled?() do
      [NotificationService.Repo, brod_client_child_spec(), message_created_child_spec()]
    else
      []
    end
  end

  defp consumer_enabled? do
    Application.get_env(:notification_service, :consumer_enabled, false) ||
      System.get_env("NOTIFICATION_CONSUMER_ENABLED") in ["true", "1", "yes"]
  end

  defp message_created_child_spec do
    %{
      id: NotificationService.Events.MessageCreatedConsumer,
      start:
        {:brod, :start_link_group_subscriber_v2,
         [
           %{
             client: @client,
             group_id: @group,
             topics: [@topic],
             cb_module: NotificationService.Events.MessageCreatedConsumer,
             consumer_config: [begin_offset: :latest],
             message_type: :message
           }
         ]}
    }
  end

  defp brod_client_child_spec do
    endpoints =
      :notification_service
      |> Application.get_env(:kafka, [])
      |> Keyword.get(:brokers, "localhost:9094")
      |> parse_endpoints()

    %{
      id: @client,
      start: {:brod, :start_link_client, [endpoints, @client, [auto_start_producers: false]]}
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
