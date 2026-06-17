defmodule SharedInfra.TestAdaptersTest do
  use ExUnit.Case, async: true

  test "Redis dummy adapter returns command plans without a live connection" do
    assert {:ok, %{command: ["PING"], opts: [timeout: 100]}} =
             SharedInfra.TestAdapters.Redis.command(["PING"], timeout: 100)

    assert {:ok, %{commands: [["PING"], ["GET", "presence:user_123"]]}} =
             SharedInfra.TestAdapters.Redis.pipeline([["PING"], ["GET", "presence:user_123"]])
  end

  test "Kafka dummy producer returns publish plans without publishing" do
    assert {:ok, %{topic: "message.events.v1", key: "message_123", value: %{type: "message_created"}}} =
             SharedInfra.TestAdapters.KafkaProducer.produce(
               "message.events.v1",
               "message_123",
               %{type: "message_created"}
             )
  end

  test "Kafka dummy consumer returns subscription and poll plans without consuming" do
    assert {:ok, %{topics: ["message.events.v1"]}} =
             SharedInfra.TestAdapters.KafkaConsumer.subscribe(["message.events.v1"])

    assert {:ok, %{messages: []}} = SharedInfra.TestAdapters.KafkaConsumer.poll()

    assert {:ok, %{message: %{offset: 10}}} =
             SharedInfra.TestAdapters.KafkaConsumer.ack(%{offset: 10})
  end

  test "Scylla dummy adapter returns query plans without a live connection" do
    assert {:ok, %{statement: "SELECT * FROM messages WHERE conversation_id = ?", opts: []}} =
             SharedInfra.TestAdapters.Scylla.prepare(
               "SELECT * FROM messages WHERE conversation_id = ?"
             )

    assert {:ok, %{statement: "SELECT * FROM messages WHERE conversation_id = ?", params: ["conv_123"]}} =
             SharedInfra.TestAdapters.Scylla.execute(
               "SELECT * FROM messages WHERE conversation_id = ?",
               ["conv_123"]
             )
  end

  test "Scylla configured client defaults to unavailable" do
    previous_adapter = Application.get_env(:shared_infra, :scylla_client_adapter)
    Application.put_env(:shared_infra, :scylla_client_adapter, SharedInfra.Scylla.UnavailableClient)

    on_exit(fn ->
      if previous_adapter do
        Application.put_env(:shared_infra, :scylla_client_adapter, previous_adapter)
      else
        Application.delete_env(:shared_infra, :scylla_client_adapter)
      end
    end)

    assert {:error, :scylla_unavailable} =
             SharedInfra.Scylla.Client.execute("SELECT now() FROM system.local", [])
  end

  test "Scylla configured client delegates to adapter" do
    previous_adapter = Application.get_env(:shared_infra, :scylla_client_adapter)
    Application.put_env(:shared_infra, :scylla_client_adapter, SharedInfra.TestAdapters.Scylla)

    on_exit(fn ->
      if previous_adapter do
        Application.put_env(:shared_infra, :scylla_client_adapter, previous_adapter)
      else
        Application.delete_env(:shared_infra, :scylla_client_adapter)
      end
    end)

    assert {:ok, %{adapter: SharedInfra.TestAdapters.Scylla, params: ["conv_123"]}} =
             SharedInfra.Scylla.Client.execute(
               "SELECT * FROM messages_by_conversation WHERE conversation_id = ?",
               ["conv_123"],
               timeout: 250
             )
  end
end
