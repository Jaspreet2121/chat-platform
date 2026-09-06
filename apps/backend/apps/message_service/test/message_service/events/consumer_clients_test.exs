defmodule MessageService.Events.ConsumerClientsTest do
  @moduledoc """
  ONE BROD CLIENT PER CONSUMER GROUP (2026-09-06) — the root-cause fix, pinned.

  brod allows exactly ONE subscriber per (client, topic, partition) — "you have to create separate
  consumers (and thus also separate clients)" (brod.erl:827-829), enforced at
  brod_consumer.erl:430-446. All four groups used to share the producer's client, so production
  showed SIX subscriptions where four groups × six partitions needs TWENTY-FOUR: three groups
  starved on every partition, retrying every 2s forever, and `brod_topic_subscriber` has no log
  statement anywhere, so none of it surfaced.

  What must therefore hold, and is asserted here:

    * every group has a client, and NO TWO GROUPS SHARE ONE — the moment two do, those two are back
      to fighting over one slot per partition;
    * no group borrows the PRODUCER's client (the exact bug);
    * every group the supervision tree starts is one this module knows, and vice versa — a group
      whose client is only in the map is never started, and one only in the tree cannot resolve a
      client at all;
    * each group's client is supervised BEFORE its subscriber: a subscriber whose client is absent
      loops on `failed to join group, reason: :client_down` — child "started", flag on, nothing
      consumed (a1de1cb).
  """
  use ExUnit.Case, async: false

  alias MessageService.Application, as: App
  alias MessageService.Events.ConsumerClients

  @flags [
    :kafka_consumer_enabled,
    :kafka_projection_consumer_enabled,
    :kafka_inbox_consumer_enabled,
    :kafka_search_consumer_enabled
  ]

  setup do
    previous =
      for key <- @flags ++ [:kafka_producer_adapter],
          into: %{},
          do: {key, Application.get_env(app_of(key), key)}

    on_exit(fn ->
      for {key, value} <- previous do
        if value == nil,
          do: Application.delete_env(app_of(key), key),
          else: Application.put_env(app_of(key), key, value)
      end
    end)

    :ok
  end

  defp app_of(:kafka_producer_adapter), do: :shared_infra
  defp app_of(_), do: :message_service

  defp enable_all_groups! do
    for flag <- @flags, do: Application.put_env(:message_service, flag, true)
    :ok
  end

  # The group a child spec serves; nil for anything that is not a group subscriber (i.e. a client).
  defp group_of(%{start: {:brod, :start_link_group_subscriber_v2, [%{group_id: group_id}]}}),
    do: group_id

  defp group_of(_spec), do: nil

  # --- the map itself ------------------------------------------------------------------------------

  test "every group has its OWN client — no two groups share one, and none is the producer's" do
    clients = ConsumerClients.client_names()

    # THE INVARIANT. Two groups sharing a client name is the original bug, restated.
    assert length(Enum.uniq(clients)) == length(clients),
           "two consumer groups share a brod client — they will contend for the single subscriber " <>
             "slot per (topic, partition) and one of them will be silently starved: " <>
             inspect(ConsumerClients.all())

    assert length(clients) == length(ConsumerClients.group_ids())

    refute SharedInfra.Kafka.BrodProducer.client_name() in clients,
           "a consumer group is running on the PRODUCER's client — the exact 2026-09-06 wedge"

    # Every name is a real, distinct atom (a nil or a duplicate would slip past the count check
    # above only if the map itself were malformed).
    for client <- clients, do: assert(is_atom(client) and client != nil)
  end

  test "client_for/1 answers per group, and REFUSES an unregistered group rather than guessing" do
    for {group_id, client} <- ConsumerClients.all() do
      assert ConsumerClients.client_for(group_id) == client
    end

    assert_raise ArgumentError, ~r/no brod client registered/, fn ->
      ConsumerClients.client_for("message-service-not-a-real-group")
    end
  end

  test "the client child spec names that group's client and never pre-starts producers" do
    endpoints = [{~c"kafka", 9092}]

    for {group_id, client} <- ConsumerClients.all() do
      assert %{id: ^client, start: {:brod, :start_link_client, args}} =
               ConsumerClients.child_spec(group_id, endpoints)

      assert [^endpoints, ^client, [auto_start_producers: false]] = args
    end
  end

  # --- the supervision tree ------------------------------------------------------------------------

  test "EVERY enabled group is preceded in the tree by its OWN client" do
    enable_all_groups!()
    children = App.kafka_children()
    ids = Enum.map(children, & &1.id)

    for {group_id, client} <- ConsumerClients.all() do
      subscriber_index = Enum.find_index(children, &(group_of(&1) == group_id))
      client_index = Enum.find_index(ids, &(&1 == client))

      assert subscriber_index, "no subscriber child for #{group_id}"
      assert client_index, "no client child (#{inspect(client)}) for #{group_id}"

      # ORDER IS THE ASSERTION: one_for_one starts in list order, and a subscriber that starts
      # before its client loops forever on :client_down without crashing.
      assert client_index < subscriber_index,
             "#{group_id}: its client #{inspect(client)} is started AFTER its subscriber " <>
               "(client at #{client_index}, subscriber at #{subscriber_index}) — the subscriber " <>
               "will loop on `failed to join group, reason: :client_down` and consume nothing"
    end
  end

  test "the tree and the map agree exactly — every started group resolves a client from this map" do
    enable_all_groups!()
    children = App.kafka_children()

    started_groups = children |> Enum.map(&group_of/1) |> Enum.reject(&is_nil/1) |> Enum.sort()

    assert started_groups == Enum.sort(ConsumerClients.group_ids())

    # ...and each subscriber was handed ITS OWN client, not a shared one.
    for child <- children, group_id = group_of(child) do
      %{start: {:brod, :start_link_group_subscriber_v2, [%{client: client}]}} = child
      assert client == ConsumerClients.client_for(group_id)
    end

    # One client child per group, no more: 4 clients + 4 subscribers.
    assert length(children) == 2 * length(ConsumerClients.group_ids())
  end

  test "a DISABLED group contributes neither a subscriber nor a client" do
    for flag <- @flags, do: Application.put_env(:message_service, flag, false)
    Application.put_env(:shared_infra, :kafka_producer_adapter, SharedInfra.Kafka.NoopProducer)

    assert App.kafka_children() == []

    # Enable exactly one: its pair appears, and nobody else's.
    Application.put_env(:message_service, :kafka_inbox_consumer_enabled, true)
    children = App.kafka_children()

    assert Enum.map(children, & &1.id) == [
             :message_service_inbox_projection_client,
             MessageService.Events.InboxProjectionConsumer
           ]
  end

  test "the PRODUCER's client rides on the producer flag alone, and is separate from every group's" do
    for flag <- @flags, do: Application.put_env(:message_service, flag, false)
    Application.put_env(:shared_infra, :kafka_producer_adapter, SharedInfra.Kafka.BrodProducer)

    assert [%{id: producer, start: {:brod, :start_link_client, args}}] = App.kafka_children()
    assert producer == SharedInfra.Kafka.BrodProducer.client_name()

    # It keeps auto_start_producers: true — the split must not disturb the produce path.
    assert [_endpoints, ^producer, [auto_start_producers: true]] = args
    refute producer in ConsumerClients.client_names()
  end
end
