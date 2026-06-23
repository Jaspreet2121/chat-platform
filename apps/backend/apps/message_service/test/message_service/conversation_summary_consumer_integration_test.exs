defmodule MessageService.ConversationSummaryConsumerIntegrationTest do
  @moduledoc """
  Wiring proof for the stateful consumer: produce a `message.created.v1` to a real
  broker → the `ConversationSummaryConsumer` applies the projection. Tagged
  `:kafka_integration` (EXCLUDED by default); run with `mix test --include kafka_integration`
  against docker Kafka on localhost:9094.

  The brod consumer worker is a SEPARATE process, so the Repo runs in SHARED sandbox
  mode (its writes are visible here and rolled back at test end). We assert via the
  consumer's test hook (so the test process isn't querying the shared connection while the
  worker writes), then read the projection row.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias MessageService.Repo
  alias MessageService.Schemas.ConversationMessageSummary
  alias MessageService.Schemas.ProcessedEvent
  alias MessageService.Projections.ConversationSummary
  alias SharedInfra.Events.Envelope
  alias SharedInfra.Kafka.BrodProducer

  @topic "message.events.v1"

  @tag :kafka_integration
  test "produce -> stateful consumer applies the conversation summary projection" do
    start_repo_shared!()

    client = BrodProducer.client_name()

    case :brod.start_link_client([{~c"localhost", 9094}], client, auto_start_producers: true) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    on_exit(fn -> :brod.stop_client(client) end)

    Application.put_env(:message_service, :conversation_summary_test_pid, self())
    on_exit(fn -> Application.delete_env(:message_service, :conversation_summary_test_pid) end)

    group = "conv-summary-test-" <> Integer.to_string(System.unique_integer([:positive]))

    {:ok, subscriber} =
      :brod.start_link_group_subscriber_v2(%{
        client: client,
        group_id: group,
        topics: [@topic],
        cb_module: MessageService.Events.ConversationSummaryConsumer,
        # :earliest on a fresh group so delivery is deterministic regardless of timing;
        # the unique conversation_id below is what we match.
        consumer_config: [begin_offset: :earliest],
        message_type: :message
      })

    Process.unlink(subscriber)
    on_exit(fn -> if Process.alive?(subscriber), do: Process.exit(subscriber, :shutdown) end)

    Process.sleep(2_000)

    conversation_id = Ecto.UUID.generate()
    event_id = Ecto.UUID.generate()

    {:ok, envelope} =
      Envelope.build(%{
        event_id: event_id,
        event_type: "message.created.v1",
        event_version: 1,
        producer: "message-service",
        occurred_at: "2026-06-18T10:00:00Z",
        correlation_id: Ecto.UUID.generate(),
        payload: %{
          "conversation_id" => conversation_id,
          "message_id" => Ecto.UUID.generate(),
          "created_at" => "2026-06-18T10:00:00Z"
        }
      })

    {:ok, encoded} = Jason.encode(envelope)
    assert :ok = :brod.produce_sync(client, @topic, :hash, conversation_id, encoded)

    # The consumer handles our event (scoped to this conversation_id) and applies the projection.
    assert_receive {:conversation_summary_applied, ^conversation_id, {:ok, :applied}}, 20_000

    # The projection + ledger rows exist (read after the worker is done with the event).
    assert %{message_count: count} = Repo.get(ConversationMessageSummary, conversation_id)
    assert count >= 1

    assert 1 ==
             Repo.aggregate(
               from(p in ProcessedEvent,
                 where:
                   p.consumer == ^ConversationSummary.consumer_name() and p.event_id == ^event_id
               ),
               :count
             )
  end

  defp start_repo_shared! do
    case Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    # No on_exit reset: Repo.start_link/0 links the Repo to the test process, so it (and
    # its sandbox connection) is torn down automatically when the test ends. A
    # `Sandbox.mode(Repo, :manual)` on_exit would run AFTER the linked Repo is already
    # dead and fail with "could not lookup Ecto repo".
  end
end
