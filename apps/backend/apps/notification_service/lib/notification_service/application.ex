defmodule NotificationService.Application do
  @moduledoc false

  use Application

  @client :notification_service_kafka_client
  @message_topic "message.events.v1"
  @message_group "notification-service-message-created"
  @conversation_topic "conversation.events.v1"
  @participants_group "notification-service-conversation-participants"

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(children(), strategy: :one_for_one, name: NotificationService.Supervisor)
  end

  # Repo is supervised at boot in dev/prod (so DB-backed requests work); NOT in :test (config
  # sets `start_repo: false`), where DataCase starts it per-test → plain `mix test` stays
  # Docker-free. The (shared) brod client + consumers start ONLY under their consumer flags
  # (both default off ⇒ no Kafka children, nothing connects at boot).
  defp children do
    repo =
      if Application.get_env(:notification_service, :start_repo, true),
        do: [NotificationService.Repo],
        else: []

    consumers =
      maybe(message_consumer_enabled?(), &message_created_child_spec/0) ++
        maybe(participants_consumer_enabled?(), &participants_child_spec/0)

    kafka =
      case consumers do
        [] -> []
        _ -> [brod_client_child_spec()] ++ consumers
      end

    repo ++ kafka
  end

  defp maybe(true, build_spec), do: [build_spec.()]
  defp maybe(false, _build_spec), do: []

  defp message_consumer_enabled? do
    Application.get_env(:notification_service, :consumer_enabled, false) ||
      System.get_env("NOTIFICATION_CONSUMER_ENABLED") in ["true", "1", "yes"]
  end

  defp participants_consumer_enabled? do
    Application.get_env(:notification_service, :participants_consumer_enabled, false) ||
      System.get_env("NOTIFICATION_PARTICIPANTS_CONSUMER_ENABLED") in ["true", "1", "yes"]
  end

  defp message_created_child_spec do
    group_subscriber_spec(
      NotificationService.Events.MessageCreatedConsumer,
      @message_topic,
      @message_group
    )
  end

  defp participants_child_spec do
    group_subscriber_spec(
      NotificationService.Events.ConversationParticipantsConsumer,
      @conversation_topic,
      @participants_group
    )
  end

  defp group_subscriber_spec(cb_module, topic, group_id) do
    %{
      id: cb_module,
      start:
        {:brod, :start_link_group_subscriber_v2,
         [
           %{
             client: @client,
             group_id: group_id,
             topics: [topic],
             cb_module: cb_module,
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
