defmodule SharedInfra.Events.EnvelopeTest do
  use ExUnit.Case, async: true

  alias SharedInfra.Events.Envelope

  @valid %{
    "event_id" => "evt_123",
    "event_type" => "message.created.v1",
    "event_version" => 1,
    "producer" => "message-service",
    "occurred_at" => "2026-06-18T10:00:00Z",
    "correlation_id" => "corr_123",
    "payload" => %{"message_id" => "m1"}
  }

  test "build fills defaults (event_version: 1, payload: %{}) and validates" do
    assert {:ok, envelope} =
             Envelope.build(%{
               "event_id" => "evt_1",
               "event_type" => "message.created.v1",
               "producer" => "message-service",
               "occurred_at" => "2026-06-18T10:00:00Z",
               "correlation_id" => "corr_1"
             })

    assert envelope.event_version == 1
    assert envelope.payload == %{}
    assert envelope.tenant_id == nil
    assert envelope.actor_user_id == nil
    assert envelope.event_type == "message.created.v1"
  end

  test "build accepts atom keys and preserves optional fields" do
    assert {:ok, envelope} =
             Envelope.build(%{
               event_id: "evt_2",
               event_type: "message.created.v1",
               event_version: 1,
               producer: "message-service",
               occurred_at: "2026-06-18T10:00:00Z",
               correlation_id: "corr_2",
               tenant_id: "tenant_1",
               actor_user_id: "user_1",
               payload: %{"a" => 1}
             })

    assert envelope.tenant_id == "tenant_1"
    assert envelope.actor_user_id == "user_1"
    assert envelope.payload == %{"a" => 1}
  end

  test "build rejects missing required fields with the missing keys" do
    assert {:error, {:invalid_envelope, missing}} =
             Envelope.build(%{"event_type" => "message.created.v1"})

    assert :event_id in missing
    assert :producer in missing
    assert :correlation_id in missing
    assert :occurred_at in missing
  end

  test "validate rejects a non-integer event_version" do
    attrs = Map.put(@valid, "event_version", "1")
    assert {:error, {:invalid_envelope, [:event_version]}} = Envelope.validate(attrs)
  end

  test "validate rejects a non-map payload" do
    attrs = Map.put(@valid, "payload", "nope")
    assert {:error, {:invalid_envelope, [:payload]}} = Envelope.validate(attrs)
  end

  test "validate accepts a fully-specified valid envelope and drops unknown keys" do
    attrs = Map.put(@valid, "event_version", 1) |> Map.put("bogus", "ignored")
    assert {:ok, envelope} = Envelope.validate(attrs)
    refute Map.has_key?(envelope, :bogus)
    assert envelope.event_id == "evt_123"
  end
end
