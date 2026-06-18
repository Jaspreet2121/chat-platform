defmodule SharedInfra.Kafka.BrodProducer do
  @moduledoc """
  Broker-backed Kafka producer adapter (brod).

  Selected ONLY when `:shared_infra, :kafka_producer_adapter` is set to this module
  (via `KAFKA_PRODUCER_ADAPTER=brod`); the default stays `NoopProducer`. The brod
  client (`client_name/0`) is started — flag-gated — by `MessageService.Application`,
  never unconditionally, so plain `mix test` connects to nothing.

  `produce/4` JSON-encodes the envelope and uses **async** `:brod.produce/5` with the
  `:hash` partitioner on the key (conversation_id) to preserve per-conversation
  ordering. Async means it never blocks the caller on a broker ack; combined with the
  `Task.start` wrap at the emit site, message creation latency is fully decoupled from
  the broker.
  """

  @behaviour SharedInfra.Kafka.Producer

  require Logger

  @client_name :message_service_kafka_client

  @doc "Registered brod client name, shared by the supervised client and this adapter."
  def client_name, do: @client_name

  @impl true
  def produce(topic, key, value, _opts \\ []) do
    case Jason.encode(value) do
      {:ok, encoded} ->
        # Async: returns {:ok, call_ref} | {:error, reason} without awaiting the broker ack.
        case :brod.produce(@client_name, topic, :hash, encode_key(key), encoded) do
          {:ok, _call_ref} -> {:ok, :produced}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("kafka produce: envelope JSON encode failed: #{inspect(reason)}")
        {:error, {:encode_failed, reason}}
    end
  end

  defp encode_key(key) when is_binary(key), do: key
  defp encode_key(nil), do: ""
  defp encode_key(key), do: to_string(key)
end
