defmodule SharedInfra.Kafka.Consumer do
  @moduledoc """
  Behaviour for Kafka consumer adapters.

  This is only a contract for future consumers; no Kafka consumption is wired
  into service supervision trees yet.
  """

  @callback subscribe(topics :: [String.t()], opts :: keyword()) :: {:ok, term()} | {:error, term()}
  @callback poll(opts :: keyword()) :: {:ok, term()} | {:error, term()}
  @callback ack(message :: term(), opts :: keyword()) :: {:ok, term()} | {:error, term()}
end
