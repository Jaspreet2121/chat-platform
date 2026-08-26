defmodule MessageService.ClientMsgDedupTest do
  @moduledoc """
  Idempotent client-message-ids (107), live against BOTH engines (the full Messages.create_message
  path: dedup ledger in Postgres, message row in Scylla, outbox staging in Postgres):

    * a RESEND with the same client_msg_id returns the FIRST write's message id as a SUCCESS and
      leaves exactly ONE Scylla row, ONE kafka_event_outbox row and ONE webhook_outbox row — the
      downstream exactly-once contract, asserted against the ledgers themselves;
    * WITHOUT client_msg_id the path is byte-identical to pre-107 (two sends → two messages);
    * composed_at is clamped into [now-7d, now] and surfaced in metadata; ordering stays server-side;
    * delivery_hint "nearby_sync" → metadata {"offline": true} — and nothing else differs;
    * a STALE claim (ledger row whose message never landed) self-heals into a fresh create.
  """
  use ExUnit.Case, async: false

  alias MessageService.Messages
  alias MessageService.Repo
  alias SharedInfra.Scylla.XandraAdapter

  @moduletag :scylla_integration

  @cluster SharedInfra.Scylla.XandraAdapter.Cluster
  @tenant_zero "00000000-0000-0000-0000-000000000001"

  setup_all do
    nodes =
      System.get_env("SCYLLA_TEST_NODES", "localhost:9042") |> String.split(",", trim: true)

    ensure_no_cluster()
    {:ok, _pid} = XandraAdapter.start_link(nodes: nodes, keyspace: "chat_messages")
    Process.sleep(2_000)

    previous = %{
      scylla: Application.get_env(:message_service, :scylla_client_adapter),
      store: Application.get_env(:message_service, :message_store_adapter),
      persistence: Application.get_env(:message_service, :message_persistence),
      publish: Application.get_env(:message_service, :kafka_publish_enabled)
    }

    # Event-outbox staging is publish-gated; enable it so exactly-once is asserted on REAL rows.
    Application.put_env(:message_service, :kafka_publish_enabled, true)

    Application.put_env(:message_service, :scylla_client_adapter, XandraAdapter)

    Application.put_env(
      :message_service,
      :message_store_adapter,
      MessageService.MessageStore.ScyllaAdapter
    )

    Application.put_env(:message_service, :message_persistence, true)

    on_exit(fn ->
      restore = fn key, value ->
        if value,
          do: Application.put_env(:message_service, key, value),
          else: Application.delete_env(:message_service, key)
      end

      restore.(:scylla_client_adapter, previous.scylla)
      restore.(:message_store_adapter, previous.store)
      restore.(:message_persistence, previous.persistence)
      restore.(:kafka_publish_enabled, previous.publish)
      ensure_no_cluster()
    end)

    :ok
  end

  setup do
    case Repo.start_link() do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    sender = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, external_id, email, password_hash, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, $4, 'x', now(), now())",
      [sender, @tenant_zero, "ext-#{sender}", "#{sender}@test.local"]
    )

    conversation = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'group', $3::text::uuid, 'active', now(), now())",
      [conversation, @tenant_zero, sender]
    )

    {:ok, sender: sender, conversation: conversation}
  end

  defp send!(conversation, sender, extra \\ %{}) do
    Map.merge(
      %{
        "conversation_id" => conversation,
        "sender_user_id" => sender,
        "message_type" => "text",
        "body" => "offline hello"
      },
      extra
    )
    |> Messages.create_message()
  end

  defp count!(sql, params) do
    %{rows: [[n]]} = Repo.query!(sql, params)
    n
  end

  defp event_outbox_count(conversation) do
    count!(
      "SELECT count(*)::int FROM kafka_event_outbox WHERE conversation_id = $1::text::uuid",
      [conversation]
    )
  end

  @tag :scylla_integration
  test "RESEND with the same client_msg_id: same message id, ONE row everywhere downstream",
       %{conversation: conversation, sender: sender} do
    client_id = Ecto.UUID.generate()

    assert {:ok, first} = send!(conversation, sender, %{"client_msg_id" => client_id})
    assert {:ok, second} = send!(conversation, sender, %{"client_msg_id" => client_id})
    assert second.message_id == first.message_id

    # Exactly one message in the store…
    assert {:ok, listing} = Messages.list_messages(%{"conversation_id" => conversation})
    assert length(listing.messages) == 1

    # …and the downstream intents fired ONCE (asserted against the ledgers, not inference).
    assert event_outbox_count(conversation) == 1

    assert count!(
             "SELECT count(*)::int FROM message_client_ids WHERE conversation_id = $1::text::uuid",
             [conversation]
           ) == 1

    # A DIFFERENT client id from the same sender is a new message.
    assert {:ok, third} = send!(conversation, sender, %{"client_msg_id" => Ecto.UUID.generate()})
    refute third.message_id == first.message_id
    assert event_outbox_count(conversation) == 2
  end

  @tag :scylla_integration
  test "WITHOUT client_msg_id the pre-107 path is untouched: two sends, two messages",
       %{conversation: conversation, sender: sender} do
    assert {:ok, first} = send!(conversation, sender)
    assert {:ok, second} = send!(conversation, sender)
    refute second.message_id == first.message_id
    assert event_outbox_count(conversation) == 2

    assert count!(
             "SELECT count(*)::int FROM message_client_ids WHERE conversation_id = $1::text::uuid",
             [conversation]
           ) == 0
  end

  @tag :scylla_integration
  test "composed_at clamps into [now-7d, now] and rides metadata; offline hint marks the message",
       %{conversation: conversation, sender: sender} do
    ancient = DateTime.utc_now() |> DateTime.add(-30 * 86_400, :second) |> DateTime.to_iso8601()

    assert {:ok, marked} =
             send!(conversation, sender, %{
               "client_msg_id" => Ecto.UUID.generate(),
               "composed_at" => ancient,
               "delivery_hint" => "nearby_sync"
             })

    metadata = marked.metadata
    assert metadata["offline"] == true

    {:ok, stored_composed, _} = DateTime.from_iso8601(metadata["composed_at"])
    floor = DateTime.add(DateTime.utc_now(), -7 * 86_400 - 60, :second)
    assert DateTime.compare(stored_composed, floor) == :gt

    # A malformed composed_at is a validation error, never silently stored.
    assert {:error, :message_invalid} =
             send!(conversation, sender, %{"composed_at" => "not-a-time"})

    # The plain path carries NEITHER marker.
    assert {:ok, plain} = send!(conversation, sender)
    refute Map.has_key?(plain.metadata, "offline")
    refute Map.has_key?(plain.metadata, "composed_at")
  end

  @tag :scylla_integration
  test "a STALE claim (message never landed) self-heals into a fresh create",
       %{conversation: conversation, sender: sender} do
    client_id = Ecto.UUID.generate()

    # A claim pointing at a message that does not exist — the crashed-create shape.
    Repo.query!(
      "INSERT INTO message_client_ids (app_id, conversation_id, sender_user_id, client_msg_id, message_id) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, $4::text::uuid, gen_random_uuid())",
      [@tenant_zero, conversation, sender, client_id]
    )

    assert {:ok, healed} = send!(conversation, sender, %{"client_msg_id" => client_id})

    # The claim now points at the REAL message, and the resend returns it.
    assert {:ok, resent} = send!(conversation, sender, %{"client_msg_id" => client_id})
    assert resent.message_id == healed.message_id
  end

  defp ensure_no_cluster do
    case Process.whereis(@cluster) do
      nil -> :ok
      pid -> Supervisor.stop(pid, :normal, 5_000)
    end

    wait_unregistered(50)
  catch
    :exit, _ -> wait_unregistered(50)
  end

  defp wait_unregistered(0), do: :ok

  defp wait_unregistered(tries) do
    case Process.whereis(@cluster) do
      nil -> :ok
      _ -> Process.sleep(20) && wait_unregistered(tries - 1)
    end
  end
end
