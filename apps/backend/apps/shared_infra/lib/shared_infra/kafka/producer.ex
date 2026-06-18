defmodule SharedInfra.Kafka.Producer do
  @moduledoc """
  Behaviour AND configured entrypoint for Kafka producer adapters.

  Mirrors `SharedInfra.Scylla.Client`: the default adapter is a non-connecting
  no-op (`SharedInfra.Kafka.NoopProducer`) so plain tests and local development
  stay Docker-free until an environment explicitly opts into a real
  broker-backed adapter. This dispatcher is DORMANT — no business flow calls it
  yet; the producer hook + live adapter land in the producer-wiring slice.
  """

  @callback produce(topic :: String.t(), key :: term(), value :: term(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  def produce(topic, key, value, opts \\ []) do
    adapter().produce(topic, key, value, opts)
  end

  def adapter do
    Application.get_env(
      :shared_infra,
      :kafka_producer_adapter,
      SharedInfra.Kafka.NoopProducer
    )
  end
end

defmodule SharedInfra.Kafka.NoopProducer do
  @moduledoc """
  Safe default Kafka producer.

  Reports that live Kafka publishing is unavailable instead of connecting to a
  broker. Selected by default so nothing connects during plain `mix test` — a
  real broker-backed adapter is wired explicitly in a later slice.
  """

  @behaviour SharedInfra.Kafka.Producer

  @impl true
  def produce(_topic, _key, _value, _opts \\ []), do: {:error, :kafka_unavailable}
end
