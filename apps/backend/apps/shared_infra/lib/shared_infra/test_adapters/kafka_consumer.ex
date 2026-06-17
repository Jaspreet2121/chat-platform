defmodule SharedInfra.TestAdapters.KafkaConsumer do
  @moduledoc """
  Offline Kafka consumer adapter for tests.
  """

  @behaviour SharedInfra.Kafka.Consumer

  @impl true
  def subscribe(topics, opts \\ []) do
    {:ok, %{adapter: __MODULE__, topics: topics, opts: opts}}
  end

  @impl true
  def poll(opts \\ []) do
    {:ok, %{adapter: __MODULE__, messages: [], opts: opts}}
  end

  @impl true
  def ack(message, opts \\ []) do
    {:ok, %{adapter: __MODULE__, message: message, opts: opts}}
  end
end
