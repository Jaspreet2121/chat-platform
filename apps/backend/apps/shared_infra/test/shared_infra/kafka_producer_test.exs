defmodule SharedInfra.Kafka.ProducerTest do
  use ExUnit.Case, async: true

  alias SharedInfra.Kafka.Producer

  test "defaults to the non-connecting NoopProducer" do
    assert Producer.adapter() == SharedInfra.Kafka.NoopProducer
  end

  test "NoopProducer reports unavailable without connecting to a broker" do
    assert {:error, :kafka_unavailable} =
             SharedInfra.Kafka.NoopProducer.produce("message.events.v1", "k", "v")
  end

  test "dispatcher routes to the configured adapter" do
    previous = Application.get_env(:shared_infra, :kafka_producer_adapter)
    Application.put_env(:shared_infra, :kafka_producer_adapter, SharedInfra.TestAdapters.KafkaProducer)

    on_exit(fn ->
      if previous do
        Application.put_env(:shared_infra, :kafka_producer_adapter, previous)
      else
        Application.delete_env(:shared_infra, :kafka_producer_adapter)
      end
    end)

    assert {:ok, %{adapter: SharedInfra.TestAdapters.KafkaProducer, topic: "message.events.v1"}} =
             Producer.produce("message.events.v1", "key", "value")
  end
end
