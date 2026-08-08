defmodule MessageService.InboxConsumerE2ETest do
  @moduledoc """
  THE SEAM ALL THREE BUGS LIVED IN (`@tag :scylla_integration`).

  The projection had a green unit suite and could not apply a single event in reality, because that
  suite used a stub whose shapes were MY ASSUMPTION rather than the adapter's contract — the same
  failure as `limit` arriving as the string "50". This suite removes the stub: every message is
  written to and read back from a REAL Scylla, and the event goes through the consumer's actual
  `handle_message/2` with a real brod record.

  ## What this covers, and what it deliberately cannot

  COVERED HERE (CI runs it — needs Scylla, NOT a broker):
    * the adapter's REAL return shape reaching the projection (bug 2)
    * `handle_message/2` -> decode -> apply -> commit_decision, the path unit tests skipped
    * the ledger transaction, against real Postgres
    * poison vs transient classification (bug 2b)

  NOT COVERED HERE, and CI cannot cover it: the FLAG-TO-CLIENT wiring (bug 1 —
  `kafka_client_needed?/0` omitting `kafka_inbox_consumer_enabled?/0`). Proving it requires booting
  the supervision tree against a live broker and observing that the brod client exists, which is a
  process-level fact no in-VM test reaches. It is verified manually by the end-to-end run; the
  symptom is `failed to join group, reason: :client_down` with the child nonetheless "started".
  Stated plainly rather than papered over with a test that would pass either way.
  """
  use MessageService.DataCase, async: false

  require Record

  alias MessageService.Events.InboxProjectionConsumer
  alias MessageService.MessageStore.ScyllaAdapter
  alias SharedInfra.Scylla.XandraAdapter

  @moduletag :scylla_integration

  @cluster SharedInfra.Scylla.XandraAdapter.Cluster
  @tenant "00000000-0000-0000-0000-000000000001"
  @gregorian_offset 0x01B21DD213814000

  Record.defrecordp(
    :kafka_message,
    Record.extract(:kafka_message, from_lib: "kafka_protocol/include/kpro_public.hrl")
  )

  setup_all do
    nodes = System.get_env("SCYLLA_TEST_NODES", "localhost:9042") |> String.split(",", trim: true)
    ensure_no_cluster()
    {:ok, _} = XandraAdapter.start_link(nodes: nodes, keyspace: "chat_messages")
    Process.sleep(2_000)

    previous = %{
      client: Application.get_env(:message_service, :scylla_client_adapter),
      adapter: Application.get_env(:message_service, :message_store_adapter)
    }

    Application.put_env(:shared_infra, :scylla_client_adapter, XandraAdapter)
    Application.put_env(:message_service, :message_store_adapter, ScyllaAdapter)

    on_exit(fn ->
      Application.put_env(:message_service, :message_store_adapter, previous.adapter)
      Application.put_env(:message_service, :scylla_client_adapter, previous.client)
      ensure_no_cluster()
    end)

    :ok
  end

  defp ensure_no_cluster do
    case Process.whereis(@cluster) do
      nil -> :ok
      pid -> Supervisor.stop(pid, :normal, 5_000)
    end
  catch
    :exit, _ -> :ok
  end

  defp uuid, do: Ecto.UUID.generate()

  # A v1 timeuuid embedding a CHOSEN instant — same layout as Messages.generate_timeuuid/0, so the
  # bucket-derivation under test sees exactly what production ids look like.
  defp timeuuid_at(%DateTime{} = dt) do
    timestamp = DateTime.to_unix(dt, :microsecond) * 10 + @gregorian_offset

    time_low = Bitwise.band(timestamp, 0xFFFF_FFFF)
    time_mid = timestamp |> Bitwise.bsr(32) |> Bitwise.band(0xFFFF)
    time_hi = timestamp |> Bitwise.bsr(48) |> Bitwise.band(0x0FFF) |> Bitwise.bor(0x1000)

    <<clock_seq::16, node::48>> = :crypto.strong_rand_bytes(8)
    clock_seq = clock_seq |> Bitwise.band(0x3FFF) |> Bitwise.bor(0x8000)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [
      time_low,
      time_mid,
      time_hi,
      clock_seq,
      node
    ])
    |> IO.iodata_to_binary()
  end

  defp user! do
    id = uuid()

    Repo.query!(
      "INSERT INTO users_auth (id,app_id,phone_number,status,created_at,updated_at) " <>
        "VALUES ($1::text::uuid,$2::text::uuid,$3,'active',now(),now())",
      [id, @tenant, "+1555#{System.unique_integer([:positive])}"]
    )

    id
  end

  defp conversation!(users) do
    id = uuid()

    Repo.query!(
      "INSERT INTO conversations (id,app_id,type,created_by,status,created_at,updated_at) " <>
        "VALUES ($1::text::uuid,$2::text::uuid,'group',$3::text::uuid,'active',now(),now())",
      [id, @tenant, hd(users)]
    )

    for u <- users do
      Repo.query!(
        "INSERT INTO conversation_participants (conversation_id,user_id,role,joined_at) " <>
          "VALUES ($1::text::uuid,$2::text::uuid,'member',now())",
        [id, u]
      )
    end

    id
  end

  # A real Scylla write, so the read-back returns the adapter's REAL shape rather than a stub's.
  defp store!(conversation_id, sender, body) do
    now = DateTime.utc_now()
    message_id = timeuuid_at(now)

    {:ok, _} =
      ScyllaAdapter.put_message(%{
        "conversation_id" => conversation_id,
        "bucket_date" => DateTime.to_date(now),
        "message_id" => message_id,
        "sender_user_id" => sender,
        "message_type" => "text",
        "body" => body,
        "status" => "active",
        "created_at" => now,
        "metadata" => %{}
      })

    message_id
  end

  # The consumer's REAL entry point, with a real brod record — not a call to the projection.
  defp deliver!(envelope, offset \\ 0) do
    record = kafka_message(offset: offset, key: "", value: Jason.encode!(envelope), ts: 0)
    InboxProjectionConsumer.handle_message(record, :state)
  end

  defp created_event(conversation_id, message_id, sender) do
    %{
      "event_id" => uuid(),
      "event_type" => "message.created.v1",
      "payload" => %{
        "conversation_id" => conversation_id,
        "message_id" => message_id,
        "sender_user_id" => sender
      }
    }
  end

  defp unread(c, u) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT unread_count FROM conversation_participants WHERE conversation_id=$1::text::uuid AND user_id=$2::text::uuid",
        [c, u]
      )

    n
  end

  defp preview(c) do
    %{rows: [[id, body]]} =
      Repo.query!(
        "SELECT last_message_id::text, last_message_body FROM conversations WHERE id=$1::text::uuid",
        [c]
      )

    {id, body}
  end

  @tag :scylla_integration
  test "THE REGRESSION: a real Scylla read-back applies through handle_message" do
    sender = user!()
    peer = user!()
    conversation = conversation!([sender, peer])
    message_id = store!(conversation, sender, "over the real seam")

    # Before the adapter fix this returned {:ok, :state} (retry) with a DBConnection.EncodeError,
    # because ScyllaAdapter handed back an ISO STRING where Postgres wanted %DateTime{} — and every
    # unit test passed because the stub returned a DateTime.
    assert {:ok, :commit, :state} =
             deliver!(created_event(conversation, message_id, sender))

    assert unread(conversation, peer) == 1
    assert unread(conversation, sender) == 0
    assert {^message_id, "over the real seam"} = preview(conversation)
  end

  @tag :scylla_integration
  test "the adapter's timestamps are the SAME TYPE the Postgres adapter returns" do
    sender = user!()
    conversation = conversation!([sender, user!()])
    message_id = store!(conversation, sender, "typed")

    {:ok, got} =
      ScyllaAdapter.get_message(%{
        "conversation_id" => conversation,
        "message_id" => message_id
      })

    # The contract, asserted directly rather than inferred from the projection working.
    assert %DateTime{} = got.created_at
  end

  @tag :scylla_integration
  test "double delivery through handle_message applies exactly once" do
    sender = user!()
    peer = user!()
    conversation = conversation!([sender, peer])
    message_id = store!(conversation, sender, "once")
    event = created_event(conversation, message_id, sender)

    assert {:ok, :commit, :state} = deliver!(event, 1)
    assert {:ok, :commit, :state} = deliver!(event, 1)
    assert unread(conversation, peer) == 1
  end

  @tag :scylla_integration
  test "an ABSENT message commits and skips (it is not an error to retry)" do
    # Renamed: this exercises the not-found path, NOT poison. It was labelled "POISON" and guarded
    # nothing about error classification — the mutation that reverts the classification left it green.
    sender = user!()

    event = %{
      "event_id" => uuid(),
      "event_type" => "message.created.v1",
      "payload" => %{
        "conversation_id" => uuid(),
        "message_id" => uuid(),
        "sender_user_id" => sender
      }
    }

    assert {:ok, :commit, :state} = deliver!(event, 2)
  end

  @tag :scylla_integration
  test "POISON: a permanent write error COMMITS (skips) rather than retrying forever" do
    # A store that hands back the pre-fix shape — an ISO STRING created_at — so the projection's
    # Postgres write raises DBConnection.EncodeError. That error can never succeed on retry; retrying
    # it wedges the partition and blocks every event behind the stuck offset. This is what the
    # classification exists for, and it must be guarded independently of the adapter being correct.
    defmodule StringTimestampStore do
      @moduledoc false
      def get_message(attrs) do
        {:ok,
         %{
           conversation_id: attrs["conversation_id"],
           message_id: attrs["message_id"],
           sender_user_id: "00000000-0000-0000-0000-0000000000aa",
           message_type: "text",
           body: "poison",
           status: "active",
           metadata: %{},
           created_at: "2026-08-08T08:31:57.063Z",
           deleted_at: nil
         }}
      end

      def list_messages(_), do: {:ok, %{messages: [], next_cursor: nil}}
    end

    previous = Application.get_env(:message_service, :message_store_adapter)
    Application.put_env(:message_service, :message_store_adapter, StringTimestampStore)
    on_exit(fn -> Application.put_env(:message_service, :message_store_adapter, previous) end)

    sender = user!()
    conversation = conversation!([sender, user!()])

    # :commit, NOT {:ok, :state}. The event is dropped deliberately and logged at :error.
    assert {:ok, :commit, :state} =
             deliver!(created_event(conversation, uuid(), sender), 7)
  end

  @tag :scylla_integration
  test "message.deleted IS PUBLISHED, and carries sender_user_id" do
    # Bug 3: deleted_message_response/1 omitted sender_user_id, so the publisher raised KeyError
    # INSIDE its own rescue — the event never fired and the failure sat in a warning. The privacy
    # fix that event exists for did not work end to end, and nothing asserted it.
    parent = self()

    defmodule DeletePublishProbe do
      @moduledoc false
      @behaviour SharedInfra.Kafka.Producer
      @impl true
      def produce(topic, key, value, _opts \\ []) do
        send(:delete_publish_probe, {:produced, topic, key, value})
        {:ok, :produced}
      end
    end

    previous = Application.get_env(:shared_infra, :kafka_producer_adapter)
    prev_publish = Application.get_env(:message_service, :kafka_publish_enabled)
    prev_persist = Application.get_env(:message_service, :message_persistence)
    Process.register(parent, :delete_publish_probe)
    Application.put_env(:shared_infra, :kafka_producer_adapter, DeletePublishProbe)
    Application.put_env(:message_service, :kafka_publish_enabled, true)
    Application.put_env(:message_service, :message_persistence, true)

    on_exit(fn ->
      Application.put_env(:shared_infra, :kafka_producer_adapter, previous)
      Application.put_env(:message_service, :kafka_publish_enabled, prev_publish)
      Application.put_env(:message_service, :message_persistence, prev_persist)
    end)

    sender = user!()
    conversation = conversation!([sender, user!()])
    message_id = store!(conversation, sender, "to be deleted")

    MessageService.Messages.delete_message(%{
      "conversation_id" => conversation,
      "message_id" => message_id,
      "actor_user_id" => sender
    })

    assert_receive {:produced, "message.events.v1", key, envelope}, 5_000

    payload = Map.get(envelope, :payload) || Map.get(envelope, "payload")

    assert (Map.get(envelope, :event_type) || Map.get(envelope, "event_type")) ==
             "message.deleted.v1"

    # SAME KEY as the create, so a delete can never overtake its create on another partition.
    assert key == conversation

    assert Map.get(payload, "sender_user_id") == sender,
           "the delete event must identify whose message was deleted"

    Process.unregister(:delete_publish_probe)
  end

  @tag :scylla_integration
  test "an unknown event type commits rather than wedging the partition" do
    assert {:ok, :commit, :state} =
             deliver!(
               %{"event_id" => uuid(), "event_type" => "message.updated.v1", "payload" => %{}},
               3
             )
  end
end
