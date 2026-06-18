defmodule MessageService.CaptureKafkaProducer do
  @moduledoc false
  # Same-process fake: create_message publishes synchronously in the test process,
  # so send(self(), ...) lands in the test mailbox for assert_received.
  @behaviour SharedInfra.Kafka.Producer

  @impl true
  def produce(topic, key, value, _opts \\ []) do
    send(self(), {:kafka_published, topic, key, value})
    {:ok, :captured}
  end
end

defmodule MessageService.FailingKafkaProducer do
  @moduledoc false
  @behaviour SharedInfra.Kafka.Producer

  @impl true
  def produce(_topic, _key, _value, _opts \\ []), do: raise("kafka broker is down")
end

defmodule MessageService.MessageCreatedEventTest do
  @moduledoc """
  Proves the fire-and-forget `message.created.v1` emission path WITHOUT a live
  broker (a fake in-process producer adapter). Docker-free, plain tests.
  """
  use ExUnit.Case, async: false

  alias MessageService.Messages
  alias MessageService.MessageStore

  @conversation_id "11111111-1111-4111-8111-111111111111"
  @sender_user_id "22222222-2222-4222-8222-222222222222"

  setup do
    previous = %{
      persistence: Application.get_env(:message_service, :message_persistence, false),
      adapter:
        Application.get_env(
          :message_service,
          :message_store_adapter,
          MessageStore.QueryPlanAdapter
        ),
      publish: Application.get_env(:message_service, :kafka_publish_enabled, false),
      producer: Application.get_env(:shared_infra, :kafka_producer_adapter)
    }

    Application.put_env(:message_service, :message_persistence, true)
    Application.put_env(:message_service, :message_store_adapter, MessageStore.InMemoryAdapter)
    start_in_memory_store!()
    MessageStore.InMemoryAdapter.reset()

    on_exit(fn ->
      MessageStore.InMemoryAdapter.reset()
      Application.put_env(:message_service, :message_persistence, previous.persistence)
      Application.put_env(:message_service, :message_store_adapter, previous.adapter)
      Application.put_env(:message_service, :kafka_publish_enabled, previous.publish)

      if previous.producer do
        Application.put_env(:shared_infra, :kafka_producer_adapter, previous.producer)
      else
        Application.delete_env(:shared_infra, :kafka_producer_adapter)
      end
    end)

    :ok
  end

  test "publishes message.created.v1 to message.events.v1 after a successful create" do
    Application.put_env(:message_service, :kafka_publish_enabled, true)

    Application.put_env(
      :shared_infra,
      :kafka_producer_adapter,
      MessageService.CaptureKafkaProducer
    )

    assert {:ok, created} =
             Messages.create_message(%{
               "conversation_id" => @conversation_id,
               "sender_user_id" => @sender_user_id,
               "message_type" => "text",
               "body" => "Hello events"
             })

    assert_received {:kafka_published, "message.events.v1", key, envelope}
    assert key == @conversation_id

    # Valid standard envelope with the expected event type + payload.
    assert envelope.event_type == "message.created.v1"
    assert envelope.event_version == 1
    assert envelope.producer == "message-service"
    assert is_binary(envelope.event_id)
    assert is_binary(envelope.correlation_id)
    assert envelope.actor_user_id == @sender_user_id
    assert envelope.payload["message_id"] == created.message_id
    assert envelope.payload["conversation_id"] == @conversation_id
    assert envelope.payload["message_type"] == "text"

    # The captured envelope is itself valid per the contract.
    assert {:ok, _} = SharedInfra.Events.Envelope.validate(envelope)
  end

  test "does NOT publish when Kafka publishing is disabled (default), create still succeeds" do
    Application.put_env(:message_service, :kafka_publish_enabled, false)

    Application.put_env(
      :shared_infra,
      :kafka_producer_adapter,
      MessageService.CaptureKafkaProducer
    )

    assert {:ok, _created} =
             Messages.create_message(%{
               "conversation_id" => @conversation_id,
               "sender_user_id" => @sender_user_id,
               "message_type" => "text",
               "body" => "No publish"
             })

    refute_received {:kafka_published, _topic, _key, _value}
  end

  test "create SUCCEEDS even when the producer raises (fire-and-forget)" do
    Application.put_env(:message_service, :kafka_publish_enabled, true)

    Application.put_env(
      :shared_infra,
      :kafka_producer_adapter,
      MessageService.FailingKafkaProducer
    )

    # The producer raises; message creation must still succeed and persist.
    assert {:ok, created} =
             Messages.create_message(%{
               "conversation_id" => @conversation_id,
               "sender_user_id" => @sender_user_id,
               "message_type" => "text",
               "body" => "Broker down"
             })

    assert created.message_id
    assert created.status == "active"

    # And the message really is persisted (durability not coupled to the broker).
    assert {:ok, timeline} = Messages.list_messages(%{"conversation_id" => @conversation_id})
    assert [listed] = timeline.messages
    assert listed.body == "Broker down"
  end

  defp start_in_memory_store! do
    case MessageStore.InMemoryAdapter.start_link() do
      {:ok, pid} ->
        Process.unlink(pid)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end
end
