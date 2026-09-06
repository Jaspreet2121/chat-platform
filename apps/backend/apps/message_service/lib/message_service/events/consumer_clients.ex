defmodule MessageService.Events.ConsumerClients do
  @moduledoc """
  ONE BROD CLIENT PER CONSUMER GROUP — the single source of truth for which client each group on
  `message.events.v1` runs on, and the root-cause fix behind four days of silent stalls.

  ## Why this module exists

  brod permits exactly ONE subscriber per consumer, and says so itself:

  > Only one process can be subscribed to a consumer. This means that if you want to read at
  > different places (or at different paces), you have to create separate consumers (and thus also
  > separate clients).  — brod.erl:827-829

  The slot is defended in `brod_consumer:handle_call({subscribe, ...})` (brod_consumer.erl:430-446),
  which answers `{error, {already_subscribed_by, Pid}}` to anyone else while the holder is alive,
  and `brod_topic_subscriber` subscribes THROUGH THE CLIENT (brod_topic_subscriber.erl:462) — so a
  client has exactly one consumer, hence one slot, per (topic, partition).

  All four of our groups used to pass `SharedInfra.Kafka.BrodProducer.client_name()`. Four groups ×
  6 partitions should be 24 subscriptions; production had SIX — one per partition. Three of the four
  groups were starved on any given partition, each retrying every 2s forever, and
  `brod_topic_subscriber` contains no log statement at all, so none of it was visible. A restart
  merely reshuffled which group won which partition. The recovery branches in
  `MessageService.Events.OffsetRecovery` cannot fix that shape: the slot's holder is alive, so the
  re-subscribe is refused.

  Separate clients give each group its own `brod_consumer` per partition, hence its own slot. The
  contention disappears by construction rather than by repair.

  ## What a separate client does NOT need to change

  The PRODUCER stays on its own client (`SharedInfra.Kafka.BrodProducer.client_name/0`,
  `auto_start_producers: true`). brod's constraint is about subscription slots only — producers are
  `brod_producer` processes under a different supervisor, keyed by (topic, partition), and
  `:brod.produce` looks one up and casts; it never subscribes. A producer can therefore share a
  client with any number of consumers safely. Keeping it separate anyway costs one client and buys
  two things: the produce path is left byte-identical (its client name is referenced by other
  services' defaults and by the integration suites), and a produce-side connection fault cannot
  stall a consumer group.

  The group clients run `auto_start_producers: false` — they never produce.

  ## The second win: connection isolation

  A brod client holds ONE payload connection per broker (`brod_client:maybe_connect/2` reuses by
  endpoint, brod_client.erl:741-747), shared by every consumer on that client. That is the
  bottleneck behind the 2026-09-05 dropped-payload-connection wedge: one dead socket stalled all
  four groups at once. Per-group clients give each group its own socket, so a dropped connection is
  now one group's problem. Group COORDINATOR connections are unchanged — `do_get_group_coordinator`
  returns an endpoint + config and each `brod_group_coordinator` already dials its own
  (brod_client.erl:684-695).

  ## Adding a group

  Add its `{group_id, client}` pair HERE and start it via `child_spec/2`. A group whose client is
  missing from this map cannot be started at all (`client_for/1` raises), which is the point: the
  old failure mode was a consumer silently running on somebody else's client.
  """

  # group_id (as passed to :brod.start_link_group_subscriber_v2) => that group's OWN client.
  # Written as literal atoms rather than derived at runtime so the set is greppable, fixed at
  # compile time, and cannot mint atoms from configuration.
  @clients %{
    "message-service-search-index" => :message_service_search_index_client,
    "message-service-inbox-projection" => :message_service_inbox_projection_client,
    "message-service-conversation-summary" => :message_service_conversation_summary_client,
    "message-service-log-consumer" => :message_service_log_consumer_client
  }

  @doc "Every {group_id, client} pair, for tests and for boot-time auditing."
  def all, do: @clients

  @doc "Every group id that owns a client here."
  def group_ids, do: Map.keys(@clients)

  @doc "Every client name this module owns (never includes the producer's client)."
  def client_names, do: Map.values(@clients)

  @doc """
  The brod client THIS group must use — for its subscriber spec and for every `:brod` call made on
  its behalf (`OffsetRecovery`'s probes above all: with per-group clients, probing the producer's
  client would answer `consumer_not_found` forever and the backstops would go blind).

  Raises for an unknown group: a consumer running on a client nobody started, or on somebody
  else's, is exactly the failure this module exists to make impossible.
  """
  def client_for(group_id) when is_binary(group_id) do
    case Map.fetch(@clients, group_id) do
      {:ok, client} ->
        client

      :error ->
        raise ArgumentError,
              "no brod client registered for consumer group #{inspect(group_id)} — add it to " <>
                "MessageService.Events.ConsumerClients.@clients (see the moduledoc: a group " <>
                "sharing another group's client is silently starved on every partition)"
    end
  end

  @doc """
  The client child spec for one group. `auto_start_producers: false` — a consumer client never
  produces, so there is nothing to pre-start.

  MUST be supervised BEFORE that group's subscriber: a subscriber whose client is absent loops on
  `failed to join group, reason: :client_down` — child "started", flag on, nothing consumed.
  """
  def child_spec(group_id, endpoints) do
    client = client_for(group_id)

    %{
      id: client,
      start: {:brod, :start_link_client, [endpoints, client, [auto_start_producers: false]]}
    }
  end
end
