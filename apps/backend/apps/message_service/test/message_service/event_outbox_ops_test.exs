defmodule MessageService.EventOutboxOpsTest do
  @moduledoc """
  The event-outbox operator surface: summary where zeros mean health, metadata-only lists, the
  envelope behind the single-row expand, and the ONE mutation — acknowledge, aborted-only,
  one-way, invisible to the relay. Plus the envelope-thinness assertion the visibility decision
  rests on: the stored envelope carries ids, never message content.
  """
  use MessageService.DataCase, async: false

  import ExUnit.CaptureLog

  alias MessageService.EventOutbox
  alias MessageService.EventOutboxOps

  defmodule SilentProducer do
    @moduledoc false
    @behaviour SharedInfra.Kafka.Producer

    @impl true
    def produce(_t, _k, _v, _o \\ []), do: {:ok, :produced}

    @impl true
    def produce_sync(topic, key, value, _o \\ []) do
      case Application.get_env(:message_service, :ops_test_pid) do
        pid when is_pid(pid) -> send(pid, {:produced_sync, topic, key, value})
        _ -> :ok
      end

      :ok
    end
  end

  setup do
    previous = %{
      publish: Application.get_env(:message_service, :kafka_publish_enabled),
      producer: Application.get_env(:shared_infra, :kafka_producer_adapter),
      pid: Application.get_env(:message_service, :ops_test_pid)
    }

    Application.put_env(:message_service, :kafka_publish_enabled, true)
    Application.put_env(:shared_infra, :kafka_producer_adapter, SilentProducer)
    Application.put_env(:message_service, :ops_test_pid, self())

    on_exit(fn ->
      restore = fn app, key, value ->
        if value, do: Application.put_env(app, key, value), else: Application.delete_env(app, key)
      end

      restore.(:message_service, :kafka_publish_enabled, previous.publish)
      restore.(:shared_infra, :kafka_producer_adapter, previous.producer)
      restore.(:message_service, :ops_test_pid, previous.pid)
    end)

    :ok
  end

  defp stage!(body_bait \\ "the secret message body") do
    # Stage through the REAL path — the envelope in the table is exactly what production stores.
    # body_bait goes into attrs the way a caller's map might carry it; the thin payload must not
    # pick it up.
    [id] =
      EventOutbox.stage_created(%{
        "conversation_id" => Ecto.UUID.generate(),
        "message_id" => Ecto.UUID.generate(),
        "sender_user_id" => Ecto.UUID.generate(),
        "body" => body_bait
      })

    id
  end

  defp set_status!(id, status) do
    Repo.query!("UPDATE kafka_event_outbox SET status = $2 WHERE id = $1::text::uuid", [
      id,
      status
    ])
  end

  @tag :postgres_integration
  test "summary: per-state counts and max ages; zeros mean health" do
    assert {:ok, empty} = EventOutboxOps.summary()
    assert empty.staged.count == 0
    assert empty.aborted.count == 0

    staged = stage!()
    aborted = stage!()
    set_status!(aborted, "aborted")

    Repo.query!(
      "UPDATE kafka_event_outbox SET created_at = now() - interval '10 minutes' " <>
        "WHERE id = $1::text::uuid",
      [staged]
    )

    assert {:ok, summary} = EventOutboxOps.summary()
    assert summary.staged.count == 1
    # The relay-health proxy: staged max age visible, here ~600s.
    assert summary.staged.max_age_seconds >= 500
    assert summary.aborted.count == 1
  end

  @tag :postgres_integration
  test "list: metadata only — the envelope never appears outside the expand" do
    id = stage!()
    set_status!(id, "aborted")

    assert {:ok, %{items: [item], count: 1}} = EventOutboxOps.list(%{"status" => "aborted"})
    assert item.id == id
    refute Map.has_key?(item, :envelope)

    # The expand carries it — same view permission, the expand IS the visibility gate.
    assert {:ok, detail} = EventOutboxOps.get(%{"id" => id})
    assert is_map(detail.envelope)
  end

  @tag :postgres_integration
  test "THE ENVELOPE IS THIN: ids only, never message content — the visibility decision's ground" do
    id = stage!("call me on 0555 123456")
    assert {:ok, %{envelope: envelope}} = EventOutboxOps.get(%{"id" => id})

    payload = envelope["payload"] || envelope[:payload]
    assert Map.keys(payload) |> Enum.sort() == ["conversation_id", "message_id", "sender_user_id"]

    # The bait never reaches the stored envelope, anywhere in it.
    refute inspect(envelope) =~ "0555 123456"
  end

  @tag :postgres_integration
  test "acknowledge: aborted -> acknowledged, one-way, evidence preserved" do
    id = stage!()
    set_status!(id, "aborted")

    Repo.query!(
      "UPDATE kafka_event_outbox SET last_error = 'scylla nodedown' WHERE id = $1::text::uuid",
      [id]
    )

    assert {:ok, %{status: "acknowledged"}} = EventOutboxOps.acknowledge(%{"id" => id})

    %{rows: [[status, last_error]]} =
      Repo.query!(
        "SELECT status, last_error FROM kafka_event_outbox WHERE id = $1::text::uuid",
        [id]
      )

    assert status == "acknowledged"
    # The evidence survives filing.
    assert last_error == "scylla nodedown"

    # One-way and aborted-only: staged and pending rows are noops, never touched.
    staged = stage!()
    assert {:ok, %{status: "noop"}} = EventOutboxOps.acknowledge(%{"id" => staged})
    pending = stage!()
    set_status!(pending, "pending")
    assert {:ok, %{status: "noop"}} = EventOutboxOps.acknowledge(%{"id" => pending})
  end

  @tag :postgres_integration
  test "TRAP 1: an acknowledged row is INVISIBLE to the relay — it can never publish" do
    id = stage!()
    set_status!(id, "aborted")
    assert {:ok, %{status: "acknowledged"}} = EventOutboxOps.acknowledge(%{"id" => id})

    # Even a zero-stale-window relay pass over the whole table: nothing publishes, the row stays.
    capture_log(fn -> EventOutbox.relay_pass(-1) end)
    refute_receive {:produced_sync, _, _, _}, 100

    %{rows: [[status]]} =
      Repo.query!("SELECT status FROM kafka_event_outbox WHERE id = $1::text::uuid", [id])

    assert status == "acknowledged"
  end
end
