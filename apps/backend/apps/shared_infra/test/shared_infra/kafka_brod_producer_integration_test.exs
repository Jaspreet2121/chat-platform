defmodule SharedInfra.Kafka.BrodProducerIntegrationTest do
  @moduledoc """
  Live-broker test for the brod-backed producer adapter. Tagged `:kafka_integration`
  and EXCLUDED by default (see test_helper) — run with
  `mix test --include kafka_integration` against docker Kafka on localhost:9094.
  Not part of Docker-free CI.
  """
  use ExUnit.Case, async: false

  alias SharedInfra.Events.Envelope
  alias SharedInfra.Kafka.BrodProducer
  alias SharedInfra.Kafka.Producer

  @topic "message.events.v1"

  @tag :kafka_integration
  test "produces a message.created.v1 envelope to a live broker via the brod adapter" do
    client = BrodProducer.client_name()
    endpoints = [{~c"localhost", 9094}]

    case :brod.start_link_client(endpoints, client, auto_start_producers: true) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    on_exit(fn -> :brod.stop_client(client) end)

    previous = Application.get_env(:shared_infra, :kafka_producer_adapter)
    Application.put_env(:shared_infra, :kafka_producer_adapter, BrodProducer)

    on_exit(fn ->
      Application.put_env(
        :shared_infra,
        :kafka_producer_adapter,
        previous || SharedInfra.Kafka.NoopProducer
      )
    end)

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

    # Sync produce confirms the live broker ACCEPTS the encoded envelope (awaits ack).
    {:ok, encoded} = Jason.encode(envelope)
    assert :ok = :brod.produce_sync(client, @topic, :hash, key, encoded)

    # The production adapter path (async) also returns ok against the live broker.
    assert {:ok, _} = Producer.produce(@topic, key, envelope)
  end
end
