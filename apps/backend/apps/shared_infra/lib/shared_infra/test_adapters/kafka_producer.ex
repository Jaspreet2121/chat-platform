defmodule SharedInfra.TestAdapters.KafkaProducer do
  @moduledoc """
  Offline Kafka producer adapter for tests.
  """

  @behaviour SharedInfra.Kafka.Producer

  @impl true
  def produce(topic, key, value, opts \\ []) do
    {:ok, %{adapter: __MODULE__, topic: topic, key: key, value: value, opts: opts}}
  end

  @impl true
  def produce_sync(_topic, _key, _value, _opts \\ []), do: :ok
end
