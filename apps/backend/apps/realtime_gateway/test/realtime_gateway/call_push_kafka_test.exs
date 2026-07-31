defmodule RealtimeGateway.CallPushKafkaTest do
  @moduledoc """
  The gateway-release Kafka fix: the brod client child is flag-gated into RealtimeGateway's supervision
  tree, and the call-push produce targets the GATEWAY'S OWN client (not message-service's, which does not
  exist in this release — the silent-death bug). Plus: a produce error now logs instead of vanishing.

  No broker anywhere: the child-spec DECISION is a pure function, and the emit path runs against a
  capturing producer fake (the CaptureKafkaProducer pattern).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias RealtimeGateway.Application, as: App
  alias RealtimeGateway.CallSignaling

  defmodule CaptureProducer do
    @behaviour SharedInfra.Kafka.Producer

    @impl true
    def produce(topic, key, value, opts \\ []) do
      case Application.get_env(:shared_infra, :capture_test_pid) do
        pid when is_pid(pid) -> send(pid, {:produced, topic, key, value, opts})
        _ -> :ok
      end

      Application.get_env(:realtime_gateway, :capture_produce_result, {:ok, :captured})
    end
  end

  defmodule UserStub do
    def get_public_profile(_attrs), do: {:ok, %{display_name: "Alice"}}
  end

  defmodule FakeEndpoint do
    def broadcast(_topic, _event, _payload), do: :ok
  end

  setup do
    prev = %{
      adapter: Application.get_env(:shared_infra, :kafka_producer_adapter),
      push: Application.get_env(:realtime_gateway, :call_push_enabled),
      user: Application.get_env(:shared_infra, :user_client_adapter),
      pid: Application.get_env(:shared_infra, :capture_test_pid),
      result: Application.get_env(:realtime_gateway, :capture_produce_result)
    }

    on_exit(fn ->
      restore(:shared_infra, :kafka_producer_adapter, prev.adapter)
      restore(:realtime_gateway, :call_push_enabled, prev.push)
      restore(:shared_infra, :user_client_adapter, prev.user)
      restore(:shared_infra, :capture_test_pid, prev.pid)
      restore(:realtime_gateway, :capture_produce_result, prev.result)
    end)

    :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp enable_push_with(producer) do
    Application.put_env(:shared_infra, :kafka_producer_adapter, producer)
    Application.put_env(:realtime_gateway, :call_push_enabled, true)
    Application.put_env(:shared_infra, :user_client_adapter, UserStub)
    Application.put_env(:shared_infra, :capture_test_pid, self())
  end

  defp ring! do
    CallSignaling.ring_callee(FakeEndpoint, "app-1", %{
      call_id: "call-1",
      room: "room-1",
      caller_id: "caller-1",
      callee_id: "callee-1",
      type: "voice",
      conversation_id: nil
    })
  end

  # --- the supervision decision (pure — no broker) ---

  test "no flags → no brod client child (plain boot connects to nothing)" do
    refute App.kafka_client_needed?()
    assert App.kafka_children() == []
  end

  test "brod adapter WITHOUT call push → no client (nothing in this release would produce)" do
    Application.put_env(:shared_infra, :kafka_producer_adapter, SharedInfra.Kafka.BrodProducer)
    refute App.kafka_client_needed?()
  end

  test "call push WITHOUT the brod adapter → no client (the noop producer needs none)" do
    Application.put_env(:realtime_gateway, :call_push_enabled, true)
    refute App.kafka_client_needed?()
  end

  test "brod adapter + call push → the GATEWAY'S OWN client child is in the tree" do
    Application.put_env(:shared_infra, :kafka_producer_adapter, SharedInfra.Kafka.BrodProducer)
    Application.put_env(:realtime_gateway, :call_push_enabled, true)

    assert App.kafka_client_needed?()

    assert [%{id: :realtime_gateway_kafka_client, start: {:brod, :start_link_client, args}}] =
             App.kafka_children()

    # The client is registered under the gateway's own name — never message-service's.
    assert [_endpoints, :realtime_gateway_kafka_client, [auto_start_producers: true]] = args
  end

  # --- the emit path ---

  test "emit_incoming_push produces with client: :realtime_gateway_kafka_client on call.events.v1" do
    enable_push_with(CaptureProducer)

    assert :ok = ring!()

    assert_receive {:produced, "call.events.v1", "callee-1", value, opts}, 1000

    # THE FIX: the gateway's own client is selected per-call (the default would target a client that
    # does not exist in this release).
    assert opts[:client] == :realtime_gateway_kafka_client

    # The producer receives the MAP — BrodProducer does the (one) JSON encode itself. The old assertion
    # here decoded a string value, i.e. it PINNED the double-encode bug.
    assert is_map(value)
    assert value["type"] == "call.incoming"
    assert value["call_id"] == "call-1"

    # The wire-bytes assertion that would have caught it: applying BrodProducer's encode step must yield
    # bytes that decode ONCE back into the event (a pre-encoded string would decode to a binary instead).
    assert value |> Jason.encode!() |> Jason.decode!() == value
  end

  test "a produce error logs a warning — and the ring still succeeds (resilience without invisibility)" do
    enable_push_with(CaptureProducer)
    Application.put_env(:realtime_gateway, :capture_produce_result, {:error, :client_down})

    log =
      capture_log(fn ->
        assert :ok = ring!()
        # The produce runs in a Task — wait for it to have fired before capture_log returns.
        assert_receive {:produced, "call.events.v1", _, _, _}, 1000
        Process.sleep(50)
      end)

    assert log =~ "call.incoming push produce failed"
    assert log =~ "client_down"
  end

  test "push disabled → nothing produced at all" do
    Application.put_env(:shared_infra, :kafka_producer_adapter, CaptureProducer)
    Application.put_env(:shared_infra, :capture_test_pid, self())
    Application.put_env(:realtime_gateway, :call_push_enabled, false)
    Application.put_env(:shared_infra, :user_client_adapter, UserStub)

    assert :ok = ring!()
    refute_receive {:produced, _, _, _, _}, 300
  end
end
