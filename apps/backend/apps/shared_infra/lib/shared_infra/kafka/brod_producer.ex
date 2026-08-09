defmodule SharedInfra.Kafka.BrodProducer do
  @moduledoc """
  Broker-backed Kafka producer adapter (brod).

  Selected ONLY when `:shared_infra, :kafka_producer_adapter` is set to this module
  (via `KAFKA_PRODUCER_ADAPTER=brod`); the default stays `NoopProducer`.

  Now that more than one service produces, the brod client is selected PER CALL via
  `opts[:client]` (e.g. conversation-service passes `client: :conversation_service_kafka_client`).
  When omitted it defaults to `client_name/0` (`:message_service_kafka_client`), so
  message-service's existing call site is unchanged. Each service's client is started —
  flag-gated — by its OWN `Application`, never unconditionally, so plain `mix test` connects
  to nothing. (A shared producer base is a separate, still-deferred refactor; this is only the
  minimal de-hardcoding needed for two producers.)

  `produce/4` JSON-encodes the envelope and uses **async** `:brod.produce/5` with the
  `:hash` partitioner on the key (conversation_id) to preserve per-conversation
  ordering. Async means it never blocks the caller on a broker ack; combined with the
  `Task.start` wrap at the emit site, message creation latency is fully decoupled from
  the broker.
  """

  @behaviour SharedInfra.Kafka.Producer

  require Logger

  @client_name :message_service_kafka_client

  @doc "Default brod client name (message-service); used when `opts[:client]` is not given."
  def client_name, do: @client_name

  @impl true
  def produce(topic, key, value, opts \\ []) do
    client = Keyword.get(opts, :client, @client_name)

    case Jason.encode(value) do
      {:ok, encoded} ->
        # Async: returns {:ok, call_ref} | {:error, reason} without awaiting the broker ack.
        case :brod.produce(client, topic, :hash, encode_key(key), encoded) do
          {:ok, _call_ref} -> {:ok, :produced}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("kafka produce: envelope JSON encode failed: #{inspect(reason)}")
        {:error, {:encode_failed, reason}}
    end
  end

  # ACK-CONFIRMED: :brod.produce_sync awaits the broker ack, so :ok here means the broker HAS the
  # event — the property the event outbox needs before it may mark a row published. Latency is the
  # broker RTT; every caller is off the request path (an unlinked Task or the relay).
  @impl true
  def produce_sync(topic, key, value, opts \\ []) do
    client = Keyword.get(opts, :client, @client_name)

    case Jason.encode(value) do
      {:ok, encoded} ->
        case :brod.produce_sync(client, topic, :hash, encode_key(key), encoded) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, {:encode_failed, reason}}
    end
  end

  defp encode_key(key) when is_binary(key), do: key
  defp encode_key(nil), do: ""
  defp encode_key(key), do: to_string(key)
end
