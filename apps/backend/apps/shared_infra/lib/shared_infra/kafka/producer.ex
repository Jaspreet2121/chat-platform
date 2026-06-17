defmodule SharedInfra.Kafka.Producer do
  @moduledoc """
  Behaviour for Kafka producer adapters.

  Business flows should not publish events through this boundary until the real
  producer implementation and delivery guarantees are designed.
  """

  @callback produce(topic :: String.t(), key :: term(), value :: term(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}
end
