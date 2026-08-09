defmodule MessageService.EventOutboxTest do
  @moduledoc """
  The kafka event outbox (096) — the C6 pattern applied to publishes. The five briefed proofs:
  the crash-window sweep verifies against the store; broker-down rows sit pending and publish on
  recovery; the flag gates staging entirely; an aborted event is never published (a phantom for a
  message that does not exist); and a REPUBLISHED event is absorbed by the consumers' ledgers —
  duplication is the recovery artifact, proven not asserted. Plus trap 4: the fast path publishes
  without waiting for any sweep interval.
  """
  use MessageService.DataCase, async: false

  alias MessageService.EventOutbox

  defmodule CapturingProducer do
    @moduledoc false
    @behaviour SharedInfra.Kafka.Producer

    @impl true
    def produce(topic, key, value, _opts \\ []) do
      notify({:produced_async, topic, key, value})
      {:ok, :produced}
    end

    @impl true
    def produce_sync(topic, key, value, _opts \\ []) do
      case Application.get_env(:message_service, :outbox_test_broker, :up) do
        :up ->
          notify({:produced_sync, topic, key, value})
          :ok

        :down ->
          {:error, :kafka_unavailable}
      end
    end

    defp notify(msg) do
      case Application.get_env(:message_service, :outbox_test_pid) do
        pid when is_pid(pid) -> send(pid, msg)
        _ -> :ok
      end
    end
  end

  defmodule StoreStub do
    @moduledoc false
    use Agent

    def start do
      case Agent.start_link(fn -> %{} end, name: __MODULE__) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end

    def reset, do: Agent.update(__MODULE__, fn _ -> %{} end)

    def put(message),
      do:
        Agent.update(
          __MODULE__,
          &Map.put(&1, {message.conversation_id, message.message_id}, message)
        )

    def get_message(attrs) do
      key = {attrs["conversation_id"], attrs["message_id"]}

      case Agent.get(__MODULE__, &Map.get(&1, key)) do
        nil -> {:error, :message_not_found}
        message -> {:ok, message}
      end
    end

    def list_messages(_attrs), do: {:ok, %{messages: [], next_cursor: nil}}
  end

  setup do
    previous = %{
      publish: Application.get_env(:message_service, :kafka_publish_enabled),
      producer: Application.get_env(:shared_infra, :kafka_producer_adapter),
      store: Application.get_env(:message_service, :message_store_adapter),
      pid: Application.get_env(:message_service, :outbox_test_pid),
      broker: Application.get_env(:message_service, :outbox_test_broker)
    }

    Application.put_env(:message_service, :kafka_publish_enabled, true)
    Application.put_env(:shared_infra, :kafka_producer_adapter, CapturingProducer)
    Application.put_env(:message_service, :message_store_adapter, StoreStub)
    Application.put_env(:message_service, :outbox_test_pid, self())
    Application.put_env(:message_service, :outbox_test_broker, :up)
    StoreStub.start()
    StoreStub.reset()

    on_exit(fn ->
      restore = fn app, key, value ->
        if value, do: Application.put_env(app, key, value), else: Application.delete_env(app, key)
      end

      restore.(:message_service, :kafka_publish_enabled, previous.publish)
      restore.(:shared_infra, :kafka_producer_adapter, previous.producer)
      restore.(:message_service, :message_store_adapter, previous.store)
      restore.(:message_service, :outbox_test_pid, previous.pid)
      restore.(:message_service, :outbox_test_broker, previous.broker)
    end)

    :ok
  end

  defp attrs do
    %{
      "conversation_id" => Ecto.UUID.generate(),
      "message_id" => Ecto.UUID.generate(),
      "sender_user_id" => Ecto.UUID.generate()
    }
  end

  defp row(id) do
    case Repo.query!(
           "SELECT status, attempts, last_error FROM kafka_event_outbox WHERE id = $1::text::uuid",
           [id]
         ) do
      %{rows: [[status, attempts, last_error]]} ->
        %{status: status, attempts: attempts, last_error: last_error}

      %{rows: []} ->
        :gone
    end
  end

  # now() is TRANSACTION-FROZEN in the sandbox (the recorded raw-SQL trap), so a row created in
  # this test is never strictly OLDER than now() — the relay's stale window can only see it if we
  # backdate it, which also mirrors reality: stale means old.
  defp backdate!(id) do
    Repo.query!(
      "UPDATE kafka_event_outbox SET created_at = now() - interval '5 minutes' " <>
        "WHERE id = $1::text::uuid",
      [id]
    )
  end

  defp put_in_store!(a, deleted \\ false) do
    StoreStub.put(%{
      conversation_id: a["conversation_id"],
      message_id: a["message_id"],
      sender_user_id: a["sender_user_id"],
      status: if(deleted, do: "deleted", else: "active"),
      deleted_at: if(deleted, do: DateTime.utc_now()),
      created_at: DateTime.utc_now(),
      body: "x"
    })
  end

  # --- trap 4: the fast path -----------------------------------------------------------------------

  @tag :postgres_integration
  test "THE FAST PATH publishes immediately — no sweep interval involved" do
    # Shared sandbox so the unlinked fast-path Task can reach this connection.
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual) end)

    a = attrs()
    [id] = EventOutbox.stage_created(a)
    assert %{status: "staged"} = row(id)

    EventOutbox.promote_and_publish_async([id])

    assert_receive {:produced_sync, "message.events.v1", key, envelope}, 2_000
    assert key == a["conversation_id"]
    assert envelope["payload"]["message_id"] || envelope[:payload]["message_id"]
    # Broker-acked -> the row is DELETED, not marked: published intent has no read value.
    assert row(id) == :gone
  end

  # --- (a) the crash window ------------------------------------------------------------------------

  @tag :postgres_integration
  test "(a) stage committed, promote never ran -> the relay verifies against the STORE and publishes" do
    a = attrs()
    put_in_store!(a)
    [id] = EventOutbox.stage_created(a)
    assert %{status: "staged"} = row(id)
    backdate!(id)

    counts = EventOutbox.relay_pass(0)

    assert counts.promoted == 1
    assert_receive {:produced_sync, "message.events.v1", _key, _env}
    assert row(id) == :gone
  end

  @tag :postgres_integration
  test "(a2) a staged row whose store row NEVER landed is aborted with evidence, not published" do
    a = attrs()
    # Nothing in the store: the put never happened (crash before the Scylla write completed and
    # the abort also never ran).
    [id] = EventOutbox.stage_created(a)
    backdate!(id)

    counts = EventOutbox.relay_pass(0)

    assert counts.aborted == 1
    refute_receive {:produced_sync, _, _, _}, 100
    assert %{status: "aborted", last_error: err} = row(id)
    assert err =~ "store contradicts"
  end

  @tag :postgres_integration
  test "(a3) store UNREACHABLE -> the row is LEFT, never aborted on an outage" do
    a = attrs()
    [id] = EventOutbox.stage_created(a)
    backdate!(id)

    # A store that answers unavailable, not absent.
    defmodule DownStore do
      def get_message(_attrs), do: {:error, :message_store_unavailable}
    end

    Application.put_env(:message_service, :message_store_adapter, DownStore)
    counts = EventOutbox.relay_pass(0)

    assert counts.left == 1
    assert %{status: "staged"} = row(id)
  end

  # --- (b) broker down -----------------------------------------------------------------------------

  @tag :postgres_integration
  test "(b) broker down -> pending sits with evidence; broker back -> the relay publishes" do
    a = attrs()
    put_in_store!(a)
    [id] = EventOutbox.stage_created(a)
    backdate!(id)

    Application.put_env(:message_service, :outbox_test_broker, :down)
    # Promote without the async task (deterministic): the relay's stale-staged path promotes, then
    # its publish fails against the down broker.
    counts = EventOutbox.relay_pass(0)
    assert counts.promoted == 1
    assert %{status: "pending", attempts: 1, last_error: err} = row(id)
    assert err =~ "kafka_unavailable"

    # Still down: another pass records another attempt, row still pending — delayed, never lost.
    assert %{failed: 1} = Map.take(EventOutbox.relay_pass(0), [:failed])
    assert %{status: "pending", attempts: 2} = row(id)

    # Broker back: the relay publishes and the row is gone.
    Application.put_env(:message_service, :outbox_test_broker, :up)
    assert %{published: 1} = Map.take(EventOutbox.relay_pass(0), [:published])
    assert_receive {:produced_sync, "message.events.v1", _, _}
    assert row(id) == :gone
  end

  # --- (c) the flag, both directions ---------------------------------------------------------------

  @tag :postgres_integration
  test "(c) KAFKA_PUBLISH_ENABLED=false -> zero rows staged, relay does nothing" do
    Application.put_env(:message_service, :kafka_publish_enabled, false)

    assert EventOutbox.stage_created(attrs()) == []

    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM kafka_event_outbox", [])
    assert n == 0

    assert EventOutbox.relay_pass(0) == %{skipped: true}
  end

  @tag :postgres_integration
  test "(c2) flag flipped OFF mid-flight: pending rows SIT — gated, not aborted — and resume on" do
    a = attrs()
    put_in_store!(a)
    [id] = EventOutbox.stage_created(a)

    Repo.query!("UPDATE kafka_event_outbox SET status = 'pending' WHERE id = $1::text::uuid", [id])

    Application.put_env(:message_service, :kafka_publish_enabled, false)
    assert EventOutbox.relay_pass(0) == %{skipped: true}
    assert %{status: "pending"} = row(id)

    Application.put_env(:message_service, :kafka_publish_enabled, true)
    assert %{published: 1} = Map.take(EventOutbox.relay_pass(0), [:published])
    assert row(id) == :gone
  end

  # --- (d) abort ------------------------------------------------------------------------------------

  @tag :postgres_integration
  test "(d) stage committed, put FAILED -> aborted with evidence and NEVER published" do
    a = attrs()
    [id] = EventOutbox.stage_created(a)

    EventOutbox.abort([id], "scylla put_message failed before promote: :nodedown")

    assert %{status: "aborted", last_error: err} = row(id)
    assert err =~ "nodedown"

    # The relay must never resurrect it: no publish for a message that does not exist.
    EventOutbox.relay_pass(0)
    refute_receive {:produced_sync, _, _, _}, 100
    assert %{status: "aborted"} = row(id)
  end

  @tag :postgres_integration
  test "(d2) a staged DELETE whose message is still LIVE is aborted — no phantom delete" do
    a = attrs()
    put_in_store!(a, false)
    [id] = EventOutbox.stage_deleted(a)
    backdate!(id)

    counts = EventOutbox.relay_pass(0)

    assert counts.aborted == 1
    refute_receive {:produced_sync, _, _, _}, 100
    assert %{status: "aborted"} = row(id)
  end

  # --- (e) duplication absorbed ---------------------------------------------------------------------

  @tag :postgres_integration
  test "(e) a REPUBLISHED event is absorbed by the consumer ledgers — counters unchanged" do
    tenant = "00000000-0000-0000-0000-000000000001"
    sender = Ecto.UUID.generate()
    peer = Ecto.UUID.generate()
    conversation = Ecto.UUID.generate()

    for u <- [sender, peer] do
      Repo.query!(
        "INSERT INTO users_auth (id, app_id, phone_number, status) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, $3, 'active')",
        [u, tenant, "+1555#{System.unique_integer([:positive])}"]
      )
    end

    Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'group', $3::text::uuid)",
      [conversation, tenant, sender]
    )

    for u <- [sender, peer] do
      Repo.query!(
        "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, 'member', now())",
        [conversation, u]
      )
    end

    message_id = Ecto.UUID.generate()

    StoreStub.put(%{
      conversation_id: conversation,
      message_id: message_id,
      sender_user_id: sender,
      message_type: "text",
      body: "dup me",
      status: "active",
      metadata: %{},
      created_at: DateTime.utc_now(),
      deleted_at: nil
    })

    envelope = %{
      "event_id" => Ecto.UUID.generate(),
      "event_type" => "message.created.v1",
      "payload" => %{
        "conversation_id" => conversation,
        "message_id" => message_id,
        "sender_user_id" => sender
      }
    }

    unread = fn ->
      %{rows: [[n]]} =
        Repo.query!(
          "SELECT unread_count FROM conversation_participants " <>
            "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
          [conversation, peer]
        )

      n
    end

    # First delivery applies; the REPUBLISH (same event_id — exactly what a relay recovery
    # produces) is refused by each ledger.
    assert {:ok, :applied} =
             MessageService.Projections.InboxFromTopic.apply_message_created(envelope)

    assert {:ok, :applied} =
             MessageService.Projections.SearchIndex.apply_message_created(envelope)

    assert unread.() == 1

    assert {:ok, :duplicate} =
             MessageService.Projections.InboxFromTopic.apply_message_created(envelope)

    assert {:ok, :duplicate} =
             MessageService.Projections.SearchIndex.apply_message_created(envelope)

    assert unread.() == 1

    %{rows: [[search_rows]]} =
      Repo.query!("SELECT count(*) FROM message_search WHERE message_id = $1::text::uuid", [
        message_id
      ])

    assert search_rows == 1
  end
end
