defmodule MessageService.Application do
  @moduledoc false

  use Application

  require Logger

  alias MessageService.Events.ConsumerClients

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
    # Repo is supervised at boot in dev/prod (so DB-backed requests work); NOT in :test
    # (config sets `start_repo: false`), where DataCase starts it per-test → Docker-free.
    repo =
      if Application.get_env(:message_service, :start_repo, true),
        do: [MessageService.Repo],
        else: []

    # The C6 write-ahead-intent sweeper rides with the repo (staged rows only exist on the Scylla
    # store path; sweeping an empty set is a no-op, so it is safe to run everywhere the repo runs).
    sweeper = if repo == [], do: [], else: [MessageService.WebhookOutboxSweeper]

    # The event-outbox relay rides with the repo exactly like the webhook sweeper (its moduledoc
    # cites that precedent). Its passes self-gate on KAFKA_PUBLISH_ENABLED, so running it where
    # publishing is off is a no-op tick, never work.
    relay = if repo == [], do: [], else: [MessageService.EventOutboxRelay]

    # C7: the shadow-mirror task supervisor is ALWAYS cheap to run (idle unless dual_write is the
    # selected adapter) and must exist before any mirror dispatches.
    shadow = [{Task.Supervisor, name: MessageService.ShadowMirror.TaskSupervisor}]

    repo ++
      sweeper ++
      relay ++ shadow ++ kafka_children() ++ scylla_children() ++ http_children()
  end

  @doc """
  The Kafka half of the tree: the PRODUCER's client (only when the brod adapter is selected), then,
  for every enabled consumer group, ITS OWN brod client immediately followed by its subscriber.

  ONE CLIENT PER GROUP is load-bearing, not tidiness — brod allows a single subscriber per
  (client, topic, partition), so four groups on one client left three of them starved on every
  partition, silently. See `MessageService.Events.ConsumerClients` for the mechanism and the
  production evidence.

  The pairing is derived from each subscriber spec's OWN `group_id` (`paired_with_client/2`), so a
  group's client can never drift from the group it serves, and the client is always ordered BEFORE
  its subscriber: a subscriber whose client is absent loops forever on `failed to join group,
  reason: :client_down` — child "started", flag on, nothing consumed (a1de1cb).
  """
  def kafka_children do
    endpoints = brod_endpoints()

    # The producer's client is now needed for the PRODUCER ALONE. It used to be OR-ed across every
    # consumer flag because the one client served them all; each group now brings its own, so that
    # trap (omit a flag → consumer with no client) is gone by construction rather than by comment.
    producer_client = if brod_producer_selected?(), do: [brod_client_child_spec()], else: []

    consumers =
      [
        {kafka_consumer_enabled?(), &kafka_consumer_child_spec/0},
        {kafka_projection_consumer_enabled?(), &conversation_summary_child_spec/0},
        # The inbox projection (086) fed from the topic. Its own flag and its own group, so it can
        # be enabled and rolled back independently of the summary projection on the same topic.
        # Safe to enable before the store cutover: the projection self-gates while PostgresAdapter
        # is selected, because that adapter maintains the same columns in-transaction and two
        # writers would double-count every unread.
        {kafka_inbox_consumer_enabled?(), &inbox_projection_child_spec/0},
        # The search-only copy of message text (DECISION_LOG 2026-08-08). Own flag, own group.
        # Unlike the inbox projection it needs no adapter self-gate — nothing else writes
        # message_search rows with different semantics, and running under the Postgres adapter just
        # keeps the index warm.
        {kafka_search_consumer_enabled?(), &search_index_child_spec/0}
      ]
      |> Enum.filter(fn {enabled?, _spec} -> enabled? end)
      |> Enum.flat_map(fn {_enabled?, spec} -> paired_with_client(spec.(), endpoints) end)

    # Make the Kafka wiring auditable at boot — a silent supervision tree masked the baked-
    # NoopProducer trap (KAFKA_PRODUCER_ADAPTER read at compile time, not runtime).
    # Each group is logged as "group_id -> its client", so the one-client-per-group property is
    # verifiable from the boot log alone — two groups naming one client is the bug, visible here.
    pairs =
      for %{start: {:brod, :start_link_group_subscriber_v2, [%{group_id: g, client: c}]}} <-
            consumers,
          do: "#{g}->#{c}"

    Logger.info(
      "kafka producer: #{inspect(Application.get_env(:shared_infra, :kafka_producer_adapter))}, " <>
        "producer client #{if producer_client == [], do: "OFF", else: "ON"}, " <>
        "consumer groups: [#{Enum.join(pairs, ", ")}]"
    )

    producer_client ++ consumers
  end

  # [that group's client, that group's subscriber] — in that order, with the client name derived
  # from the subscriber's OWN group_id so the two can never disagree.
  defp paired_with_client(
         %{start: {:brod, :start_link_group_subscriber_v2, [%{group_id: group_id}]}} = subscriber,
         endpoints
       ) do
    [MessageService.Events.ConsumerClients.child_spec(group_id, endpoints), subscriber]
  end

  # ScyllaDB driver (Phase B) — DRIVER ONLY: this starts a connection pool, it does NOT make Scylla
  # the message store (MESSAGE_STORE_ADAPTER still selects Postgres) and nothing writes to it.
  #
  # Started ONLY when `config :message_service, :scylla, nodes: [...]` is populated, which runtime.exs
  # does solely from SCYLLA_NODES. Absent env → NO child → boot is byte-identical to today, and
  # SharedInfra.Scylla.Client keeps returning the unavailable stub. The child itself can never break
  # boot: XandraAdapter.start_link/1 returns :ignore rather than an error on any failure, so an
  # unreachable or misconfigured cluster leaves the supervisor (and all Postgres-backed traffic)
  # completely unaffected. shared_infra has no supervision tree of its own, so message_service — the
  # only consumer — is the correct home.
  defp scylla_children do
    config = MessageService.Infrastructure.scylla_config()

    if scylla_configured?(config) do
      [{SharedInfra.Scylla.XandraAdapter, config}]
    else
      []
    end
  end

  defp scylla_configured?(config) do
    Application.get_env(:message_service, :scylla) != nil and
      Keyword.get(config, :nodes, []) != []
  end

  # Internal HTTP API listener starts ONLY under MESSAGE_HTTP_API_ENABLED (default off), so the
  # umbrella boot + plain `mix test` start no listener. Bind on a private network in deployment.
  defp http_children do
    if http_api_enabled?() do
      [
        {Plug.Cowboy,
         scheme: :http, plug: MessageService.HTTP.Router, options: [port: http_port()]}
      ]
    else
      []
    end
  end

  defp http_api_enabled? do
    Application.get_env(:message_service, :http_api_enabled, false) ||
      System.get_env("MESSAGE_HTTP_API_ENABLED") in ["true", "1", "yes"]
  end

  defp http_port do
    Application.get_env(:message_service, :http_port) ||
      String.to_integer(System.get_env("MESSAGE_HTTP_PORT") || "4104")
  end

  # (There used to be a `kafka_client_needed?/0` here OR-ing every consumer flag with the producer's,
  # because one client served them all — and omitting a flag started a consumer with NO client,
  # which then looped forever on `failed to join group, reason: :client_down`: child "started",
  # flag on, nothing consumed (a1de1cb). Each group now carries its own client in the same
  # `paired_with_client/2` pair, so there is no list left to forget to update.)

  defp brod_producer_selected? do
    Application.get_env(:shared_infra, :kafka_producer_adapter) ==
      SharedInfra.Kafka.BrodProducer
  end

  defp kafka_consumer_enabled? do
    Application.get_env(:message_service, :kafka_consumer_enabled, false) ||
      System.get_env("KAFKA_CONSUMER_ENABLED") in ["true", "1", "yes"]
  end

  defp kafka_projection_consumer_enabled? do
    Application.get_env(:message_service, :kafka_projection_consumer_enabled, false) ||
      System.get_env("KAFKA_PROJECTION_CONSUMER_ENABLED") in ["true", "1", "yes"]
  end

  defp kafka_inbox_consumer_enabled? do
    Application.get_env(:message_service, :kafka_inbox_consumer_enabled, false) ||
      System.get_env("KAFKA_INBOX_CONSUMER_ENABLED") in ["true", "1", "yes"]
  end

  defp kafka_search_consumer_enabled? do
    Application.get_env(:message_service, :kafka_search_consumer_enabled, false) ||
      System.get_env("KAFKA_SEARCH_CONSUMER_ENABLED") in ["true", "1", "yes"]
  end

  defp search_index_child_spec do
    group_id = "message-service-search-index"

    %{
      id: MessageService.Events.SearchIndexConsumer,
      start:
        {:brod, :start_link_group_subscriber_v2,
         [
           %{
             client: ConsumerClients.client_for(group_id),
             group_id: group_id,
             topics: ["message.events.v1"],
             cb_module: MessageService.Events.SearchIndexConsumer,
             # :earliest for the inbox consumer's recorded reason: a first enable must index the
             # retained backlog, not skip it. Replay is ledger-idempotent, and an old create can
             # never resurrect deleted text — the read-back finds the tombstone.
             consumer_config: [begin_offset: :earliest],
             message_type: :message
           }
         ]},
      restart: :permanent,
      type: :worker
    }
  end

  defp inbox_projection_child_spec do
    group_id = "message-service-inbox-projection"

    %{
      id: MessageService.Events.InboxProjectionConsumer,
      start:
        {:brod, :start_link_group_subscriber_v2,
         [
           %{
             client: ConsumerClients.client_for(group_id),
             group_id: group_id,
             topics: ["message.events.v1"],
             cb_module: MessageService.Events.InboxProjectionConsumer,
             # :earliest, NOT :latest. With :latest a consumer that has never committed on a
             # partition SKIPS whatever is already there — a first enable silently drops the existing
             # backlog, which is the failure shape this consumer has already produced three of.
             # Replay is safe because the projection is ledger-idempotent: see
             # Projections.InboxFromTopic's "Replaying from offset zero" note for what is and is NOT
             # covered (events older than the ledger's first row inflate unread; the preview cannot
             # be clobbered).
             consumer_config: [begin_offset: :earliest],
             message_type: :message
           }
         ]}
    }
  end

  defp conversation_summary_child_spec do
    group_id = "message-service-conversation-summary"

    %{
      id: MessageService.Events.ConversationSummaryConsumer,
      start:
        {:brod, :start_link_group_subscriber_v2,
         [
           %{
             client: ConsumerClients.client_for(group_id),
             group_id: group_id,
             topics: ["message.events.v1"],
             cb_module: MessageService.Events.ConversationSummaryConsumer,
             consumer_config: [begin_offset: :latest],
             message_type: :message
           }
         ]}
    }
  end

  defp kafka_consumer_child_spec do
    group_id = "message-service-log-consumer"

    %{
      id: MessageService.Events.MessageCreatedLogConsumer,
      start:
        {:brod, :start_link_group_subscriber_v2,
         [
           %{
             client: ConsumerClients.client_for(group_id),
             group_id: group_id,
             topics: ["message.events.v1"],
             cb_module: MessageService.Events.MessageCreatedLogConsumer,
             consumer_config: [begin_offset: :latest],
             message_type: :message
           }
         ]}
    }
  end

  defp brod_endpoints do
    MessageService.Infrastructure.kafka_config()
    |> Keyword.get(:brokers, "localhost:9094")
    |> parse_endpoints()
  end

  # The PRODUCER's client only. Consumer groups each get their own (ConsumerClients.child_spec/2);
  # this one keeps `auto_start_producers: true` and its long-standing name, so the produce path is
  # untouched by the split.
  defp brod_client_child_spec do
    %{
      id: SharedInfra.Kafka.BrodProducer.client_name(),
      start:
        {:brod, :start_link_client,
         [
           brod_endpoints(),
           SharedInfra.Kafka.BrodProducer.client_name(),
           [auto_start_producers: true]
         ]}
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
