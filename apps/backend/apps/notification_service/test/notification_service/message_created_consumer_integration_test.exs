defmodule NotificationService.MessageCreatedConsumerIntegrationTest do
  @moduledoc """
  Wiring proof: produce a `message.created.v1` to a real broker → the
  `MessageCreatedConsumer` writes a notification. Tagged `:kafka_integration` (EXCLUDED by
  default); run with `mix test --include kafka_integration` against docker Kafka on
  localhost:9094.

  The brod consumer worker is a SEPARATE process, so the Repo runs in SHARED sandbox mode
  (its writes are visible here and rolled back at test end). We assert via the consumer's
  test hook (so the test process isn't querying the shared connection while the worker
  writes), then read the notification row.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias NotificationService.Repo
  alias NotificationService.Schemas.Notification

  @client :notification_service_kafka_client
  @topic "message.events.v1"

  @tag :kafka_integration
  test "produce -> consumer writes a notification record" do
    start_repo_shared!()

    case :brod.start_link_client([{~c"localhost", 9094}], @client, auto_start_producers: true) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    on_exit(fn -> :brod.stop_client(@client) end)

    Application.put_env(:notification_service, :notification_test_pid, self())
    on_exit(fn -> Application.delete_env(:notification_service, :notification_test_pid) end)

    group = "notif-test-" <> Integer.to_string(System.unique_integer([:positive]))

    {:ok, subscriber} =
      :brod.start_link_group_subscriber_v2(%{
        client: @client,
        group_id: group,
        topics: [@topic],
        cb_module: NotificationService.Events.MessageCreatedConsumer,
        # :earliest on a fresh group so delivery is deterministic; the unique event_id
        # below is what we match.
        consumer_config: [begin_offset: :earliest],
        message_type: :message
      })

    Process.unlink(subscriber)
    on_exit(fn -> if Process.alive?(subscriber), do: Process.exit(subscriber, :shutdown) end)

    Process.sleep(2_000)

    event_id = Ecto.UUID.generate()
    conversation_id = Ecto.UUID.generate()

    envelope = %{
      "event_id" => event_id,
      "event_type" => "message.created.v1",
      "event_version" => 1,
      "producer" => "message-service",
      "occurred_at" => "2026-06-18T10:00:00Z",
      "correlation_id" => Ecto.UUID.generate(),
      "payload" => %{
        "conversation_id" => conversation_id,
        "message_id" => Ecto.UUID.generate(),
        "sender_user_id" => Ecto.UUID.generate(),
        "message_type" => "text",
        "created_at" => "2026-06-18T10:00:00Z"
      }
    }

    {:ok, encoded} = Jason.encode(envelope)
    assert :ok = :brod.produce_sync(@client, @topic, :hash, conversation_id, encoded)

    # The consumer handles our event (scoped to this event_id) and writes the notification.
    assert_receive {:notification_applied, ^event_id, {:ok, :applied}}, 20_000

    notification = Repo.one(from(n in Notification, where: n.source_event_id == ^event_id))
    assert notification
    assert notification.type == "message_created"
    assert notification.conversation_id == conversation_id
  end

  defp start_repo_shared! do
    case Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    # No on_exit reset: Repo.start_link/0 links the Repo to the test process, so it is torn
    # down automatically when the test ends.
    :ok
  end
end
