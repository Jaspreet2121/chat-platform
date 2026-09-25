defmodule MessageService.InboxRecountScyllaTest do
  @moduledoc """
  The store-backed unread recount, against a REAL Scylla — the adapter production runs.

  The scenario is the known bug's: the maintained counter is wrong (here, zeroed by hand — exactly
  what the Postgres lateral did against the empty table) while the store holds the truth. A recount
  must put the counter back to what the projection would have maintained: unread = the sender's
  messages inside the reader's window, minus the ones the reader has already claimed as read.
  """
  use ExUnit.Case, async: false

  alias MessageService.InboxRecount
  alias MessageService.Messages
  alias MessageService.MessageStore
  alias MessageService.Repo
  alias SharedInfra.Scylla.XandraAdapter

  @moduletag :scylla_integration

  @cluster SharedInfra.Scylla.XandraAdapter.Cluster
  @tenant "00000000-0000-0000-0000-000000000001"

  setup_all do
    nodes = System.get_env("SCYLLA_TEST_NODES", "localhost:9042") |> String.split(",", trim: true)
    ensure_no_cluster()
    {:ok, _pid} = XandraAdapter.start_link(nodes: nodes, keyspace: "chat_messages")
    Process.sleep(2_000)

    previous = %{
      scylla: Application.get_env(:message_service, :scylla_client_adapter),
      store: Application.get_env(:message_service, :message_store_adapter),
      persistence: Application.get_env(:message_service, :message_persistence)
    }

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

    reader = user!()
    sender = user!()
    conversation = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by, status) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'direct', $3::text::uuid, 'active')",
      [conversation, @tenant, sender]
    )

    for u <- [reader, sender] do
      Repo.query!(
        "INSERT INTO conversation_participants (conversation_id, user_id) VALUES ($1::text::uuid, $2::text::uuid)",
        [conversation, u]
      )
    end

    {:ok, reader: reader, sender: sender, conversation: conversation}
  end

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, status) VALUES ($1::text::uuid, $2::text::uuid, $3, 'active')",
      [id, @tenant, "+1555#{System.unique_integer([:positive])}"]
    )

    id
  end

  defp send!(conversation, sender, body) do
    {:ok, message} =
      Messages.create_message(%{
        "conversation_id" => conversation,
        "sender_user_id" => sender,
        "message_type" => "text",
        "body" => body
      })

    message
  end

  defp counter(conversation, user) do
    %{rows: [[n, oldest]]} =
      Repo.query!(
        "SELECT unread_count, oldest_unread_at FROM conversation_participants " <>
          "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
        [conversation, user]
      )

    {n, oldest}
  end

  defp zero!(conversation, user) do
    Repo.query!(
      "UPDATE conversation_participants SET unread_count = 0, oldest_unread_at = NULL " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [conversation, user]
    )
  end

  test "restores a zeroed counter from the store: sender's messages minus the reader's read marks",
       %{reader: reader, sender: sender, conversation: conversation} do
    messages = for i <- 1..5, do: send!(conversation, sender, "m#{i}")
    [m1, m2 | _] = messages

    # The reader opens the first two: read receipts + the projection's read marks + decrements.
    for m <- [m1, m2] do
      {:ok, _} =
        MessageStore.mark_read(%{
          "conversation_id" => conversation,
          "message_id" => to_string(m.message_id),
          "user_id" => reader
        })
    end

    # THE BUG SCENARIO: the maintained counter is wrong (the frozen-table lateral wrote 0).
    zero!(conversation, reader)
    assert {0, nil} = counter(conversation, reader)

    assert {:ok, %{unread_count: 3, oldest_unread_at: oldest}} =
             InboxRecount.recount(conversation, reader)

    assert is_binary(oldest)

    {n, oldest_at} = counter(conversation, reader)
    assert n == 3
    # The oldest unread is the THIRD message — the first two are read.
    # Scylla stores timestamps at MILLISECOND precision; the create response carries the original
    # microsecond value, so the stored watermark can read a hair earlier. Compare at the
    # millisecond, and pin the ORDER against the second (read) message, which must be strictly
    # before it.
    third = Enum.at(messages, 2)
    {:ok, third_at, _} = DateTime.from_iso8601(to_string(third.created_at))
    {:ok, second_at, _} = DateTime.from_iso8601(to_string(m2.created_at))
    assert abs(DateTime.diff(oldest_at, third_at, :millisecond)) < 2
    assert DateTime.compare(oldest_at, second_at) == :gt
  end

  test "the sender's own messages never count, and a cleared conversation starts from cleared_before",
       %{reader: reader, sender: sender, conversation: conversation} do
    for i <- 1..4, do: send!(conversation, sender, "m#{i}")

    assert {:ok, %{unread_count: 0}} = InboxRecount.recount(conversation, sender)

    # The reader clears the chat after message 4; a message after that is the only unread.
    # clock_timestamp(), not now(): now() is frozen at the sandbox transaction's start, which is
    # BEFORE every message this test sent.
    Repo.query!(
      "UPDATE conversation_participants SET cleared_before = clock_timestamp() WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [conversation, reader]
    )

    Process.sleep(20)
    send!(conversation, sender, "after clear")

    assert {:ok, %{unread_count: 1}} = InboxRecount.recount(conversation, reader)
  end

  test "a store that cannot be read leaves the counter exactly as it was — never 0",
       %{reader: reader, sender: sender, conversation: conversation} do
    for i <- 1..3, do: send!(conversation, sender, "m#{i}")

    # Under Scylla the INCREMENT is the Kafka projection's, which does not run here — so set the
    # maintained value by hand. What is under test is that a failed recount does not move it.
    Repo.query!(
      "UPDATE conversation_participants SET unread_count = 3 WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [conversation, reader]
    )

    assert {3, _} = counter(conversation, reader)

    previous = Application.get_env(:message_service, :message_store_adapter)

    Application.put_env(
      :message_service,
      :message_store_adapter,
      MessageService.MessageStore.QueryPlanAdapter
    )

    try do
      assert {:error, _} = InboxRecount.recount(conversation, reader)
    after
      Application.put_env(:message_service, :message_store_adapter, previous)
    end

    assert {3, _} = counter(conversation, reader)
  end

  defp ensure_no_cluster do
    case Process.whereis(@cluster) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end
end
