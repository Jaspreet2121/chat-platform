defmodule MessageService.MessageCreatedConsumerIntegrationTest do
  @moduledoc """
  Live round-trip for the minimal log/ack consumer: produce a `message.created.v1`
  to a real broker, the group subscriber handles it and (via the test hook) forwards
  it to this process. Tagged `:kafka_integration` and EXCLUDED by default — run with
  `mix test --include kafka_integration` against docker Kafka on localhost:9094.
  Not part of Docker-free CI.
  """
  use ExUnit.Case, async: false

  alias SharedInfra.Events.Envelope
  alias SharedInfra.Kafka.BrodProducer

  @topic "message.events.v1"

  @tag :kafka_integration
  test "produce -> consume round-trip: the log consumer handles message.created.v1" do
    client = BrodProducer.client_name()
    endpoints = [{~c"localhost", 9094}]

    case :brod.start_link_client(endpoints, client, auto_start_producers: true) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    on_exit(fn -> :brod.stop_client(client) end)

    Application.put_env(:message_service, :kafka_consumer_test_pid, self())
    on_exit(fn -> Application.delete_env(:message_service, :kafka_consumer_test_pid) end)

    # Fresh group (no committed offset) so begin_offset: :latest applies cleanly.
    group_id = "msg-consumer-test-" <> Integer.to_string(System.unique_integer([:positive]))

    # Test uses :earliest on a FRESH group (no committed offset) so it deterministically
    # reads the produced message regardless of join/produce timing — matched by a unique
    # key below. (Production uses :latest in MessageService.Application to avoid replay.)
    {:ok, subscriber} =
      :brod.start_link_group_subscriber_v2(%{
        client: client,
        group_id: group_id,
        topics: [@topic],
        cb_module: MessageService.Events.MessageCreatedLogConsumer,
        consumer_config: [begin_offset: :earliest],
        message_type: :message
      })

    Process.unlink(subscriber)
    on_exit(fn -> if Process.alive?(subscriber), do: Process.exit(subscriber, :shutdown) end)

    # Let the group join + assign partitions.
    Process.sleep(2_000)

    key = "conv-" <> Integer.to_string(System.unique_integer([:positive]))

    {:ok, envelope} =
      Envelope.build(%{
        event_id: "evt-" <> key,
        event_type: "message.created.v1",
        event_version: 1,
        producer: "message-service",
        occurred_at: "2026-06-18T10:00:00Z",
        correlation_id: "corr-" <> key,
        actor_user_id: "user-1",
        payload: %{"conversation_id" => key, "message_id" => "m-" <> key}
      })

    {:ok, encoded} = Jason.encode(envelope)
    assert :ok = :brod.produce_sync(client, @topic, :hash, key, encoded)

    assert_receive {:kafka_consumed, consumed, ^key, _offset}, 20_000
    assert consumed["event_type"] == "message.created.v1"
    assert consumed["event_id"] == "evt-" <> key
  end
end
