defmodule SharedInfra.ConfigTest do
  use ExUnit.Case, async: true

  alias SharedInfra.Config.{Kafka, Redis, Scylla}

  describe "Redis config" do
    test "reads configured redis placeholders" do
      assert Redis.from_app(:realtime_gateway) == [url: "redis://localhost:6379/0", timeout: 1_000]
    end

    test "falls back safely when config is missing" do
      assert Redis.from_app(:missing_app) == [url: "redis://localhost:6379/0", timeout: 1_000]
      assert Redis.normalize(:invalid) == [url: "redis://localhost:6379/0", timeout: 1_000]
    end
  end

  describe "Kafka config" do
    test "reads message service kafka placeholders" do
      assert Kafka.from_app(:message_service) == [
               brokers: "localhost:9094",
               client_id: "message-service"
             ]
    end

    test "reads realtime gateway kafka placeholders" do
      assert Kafka.from_app(:realtime_gateway) == [
               brokers: "localhost:9094",
               client_id: "realtime-gateway"
             ]
    end

    test "falls back safely when config is missing" do
      assert Kafka.from_app(:missing_app) == [
               brokers: "localhost:9094",
               client_id: "missing-app"
             ]

      assert Kafka.normalize(:invalid, "custom-client") == [
               brokers: "localhost:9094",
               client_id: "custom-client"
             ]
    end
  end

  describe "Scylla config" do
    test "reads message service scylla placeholders" do
      assert Scylla.from_app(:message_service) == [
               nodes: [{"localhost", 9042}],
               contact_points: [{"localhost", 9042}],
               keyspace: "chat_messages",
               timeout: 5_000
             ]
    end

    test "falls back safely when config is missing" do
      assert Scylla.from_app(:missing_app) == [
               nodes: [{"localhost", 9042}],
               contact_points: [{"localhost", 9042}],
               keyspace: "chat_messages",
               timeout: 5_000
             ]

      assert Scylla.normalize(:invalid) == [
               nodes: [{"localhost", 9042}],
               contact_points: [{"localhost", 9042}],
               keyspace: "chat_messages",
               timeout: 5_000
             ]
    end

    test "normalizes contact points and timeout" do
      assert Scylla.normalize(contact_points: [{"scylla", 9042}], keyspace: "chat", timeout: 250) == [
               nodes: [{"scylla", 9042}],
               contact_points: [{"scylla", 9042}],
               keyspace: "chat",
               timeout: 250
             ]
    end
  end
end
