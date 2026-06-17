defmodule MessageService.TestScyllaClient do
  @moduledoc false

  @behaviour SharedInfra.Scylla.Client

  use Agent

  @name __MODULE__

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> [] end, name: @name)
  end

  def reset do
    ensure_started()
    Agent.update(@name, fn _messages -> [] end)
  end

  @impl true
  def prepare(statement, opts \\ []) do
    {:ok, %{statement: statement, opts: opts}}
  end

  @impl true
  def execute(statement, params, opts \\ []) do
    ensure_started()

    cond do
      String.contains?(statement, "INSERT INTO messages_by_conversation") ->
        Agent.update(@name, fn messages -> [message_from_params(params) | messages] end)
        {:ok, %{statement: statement, params: params, opts: opts}}

      String.contains?(statement, "INSERT INTO message_receipts_by_conversation") ->
        {:ok, %{statement: statement, params: params, opts: opts}}

      String.contains?(statement, "SET body = ?, status = ?, edited_at = ?") ->
        [body, status, edited_at, conversation_id, bucket_date, message_id] = params

        update_message(conversation_id, bucket_date, message_id, %{
          body: body,
          status: status,
          edited_at: edited_at
        })

        {:ok, %{statement: statement, params: params, opts: opts}}

      String.contains?(statement, "SET status = ?, deleted_at = ?") ->
        [status, deleted_at, conversation_id, bucket_date, message_id] = params

        update_message(conversation_id, bucket_date, message_id, %{
          status: status,
          deleted_at: deleted_at
        })

        {:ok, %{statement: statement, params: params, opts: opts}}

      String.contains?(statement, "FROM messages_by_conversation") ->
        [conversation_id, bucket_date, limit] = params

        rows =
          @name
          |> Agent.get(& &1)
          |> Enum.filter(
            &(&1.conversation_id == conversation_id and &1.bucket_date == bucket_date)
          )
          |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
          |> Enum.take(limit)

        {:ok, %{statement: statement, params: params, opts: opts, rows: rows}}

      true ->
        {:error, :unexpected_statement}
    end
  end

  defp message_from_params([
         conversation_id,
         bucket_date,
         message_id,
         sender_user_id,
         message_type,
         body,
         media_id,
         reply_to_message_id,
         status,
         metadata,
         created_at,
         edited_at,
         deleted_at
       ]) do
    %{
      conversation_id: conversation_id,
      bucket_date: bucket_date,
      message_id: message_id,
      sender_user_id: sender_user_id,
      message_type: message_type,
      body: body,
      media_id: media_id,
      reply_to_message_id: reply_to_message_id,
      status: status,
      metadata: metadata,
      created_at: created_at,
      edited_at: edited_at,
      deleted_at: deleted_at
    }
  end

  defp update_message(conversation_id, bucket_date, message_id, updates) do
    Agent.update(@name, fn messages ->
      Enum.map(messages, fn message ->
        if message.conversation_id == conversation_id and message.bucket_date == bucket_date and
             message.message_id == message_id do
          Map.merge(message, updates)
        else
          message
        end
      end)
    end)
  end

  defp ensure_started do
    case Process.whereis(@name) do
      nil ->
        {:ok, _pid} = start_link()
        :ok

      _pid ->
        :ok
    end
  end
end

defmodule MessageService.MessageStoreBoundaryTest do
  use ExUnit.Case, async: false

  alias MessageService.MessageStore
  alias MessageService.Messages
  alias MessageService.Receipts

  @conversation_id "11111111-1111-4111-8111-111111111111"
  @sender_user_id "22222222-2222-4222-8222-222222222222"
  @receipt_user_id "33333333-3333-4333-8333-333333333333"

  setup do
    previous_persistence = Application.get_env(:message_service, :message_persistence, false)

    previous_adapter =
      Application.get_env(
        :message_service,
        :message_store_adapter,
        MessageStore.QueryPlanAdapter
      )

    previous_client_adapter = Application.get_env(:message_service, :scylla_client_adapter)
    previous_shared_client_adapter = Application.get_env(:shared_infra, :scylla_client_adapter)

    Application.put_env(:message_service, :message_persistence, true)
    Application.put_env(:message_service, :message_store_adapter, MessageStore.InMemoryAdapter)

    start_in_memory_store!()
    MessageStore.InMemoryAdapter.reset()
    start_test_scylla_client!()
    MessageService.TestScyllaClient.reset()

    on_exit(fn ->
      MessageStore.InMemoryAdapter.reset()
      MessageService.TestScyllaClient.reset()
      Application.put_env(:message_service, :message_persistence, previous_persistence)
      Application.put_env(:message_service, :message_store_adapter, previous_adapter)

      if previous_client_adapter do
        Application.put_env(:message_service, :scylla_client_adapter, previous_client_adapter)
      else
        Application.delete_env(:message_service, :scylla_client_adapter)
      end

      if previous_shared_client_adapter do
        Application.put_env(:shared_infra, :scylla_client_adapter, previous_shared_client_adapter)
      else
        Application.delete_env(:shared_infra, :scylla_client_adapter)
      end
    end)

    :ok
  end

  test "create_message persists a DB-backed text message through the configured store" do
    assert {:ok, message} =
             Messages.create_message(%{
               "conversation_id" => @conversation_id,
               "sender_user_id" => @sender_user_id,
               "message_type" => "text",
               "body" => "Hello from the boundary",
               "metadata" => %{"client_id" => "local-test"}
             })

    assert message.conversation_id == @conversation_id

    assert message.message_id =~
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-1[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

    assert message.sender_user_id == @sender_user_id
    assert message.message_type == "text"
    assert message.body == "Hello from the boundary"
    assert message.status == "active"
    assert message.metadata == %{"client_id" => "local-test"}
    assert is_binary(message.created_at)
  end

  test "list_messages returns persisted messages newest first" do
    assert {:ok, first} =
             Messages.create_message(%{
               "conversation_id" => @conversation_id,
               "sender_user_id" => @sender_user_id,
               "message_type" => "text",
               "body" => "First"
             })

    Process.sleep(2)

    assert {:ok, second} =
             Messages.create_message(%{
               "conversation_id" => @conversation_id,
               "sender_user_id" => @sender_user_id,
               "message_type" => "text",
               "body" => "Second"
             })

    assert {:ok, timeline} = Messages.list_messages(%{"conversation_id" => @conversation_id})

    assert timeline.conversation_id == @conversation_id
    assert Enum.map(timeline.messages, & &1.message_id) == [second.message_id, first.message_id]
    assert timeline.next_cursor == nil
  end

  test "create_message validates required DB-backed fields" do
    assert {:error, :message_invalid} =
             Messages.create_message(%{
               "conversation_id" => @conversation_id,
               "sender_user_id" => @sender_user_id,
               "message_type" => "text"
             })

    assert {:error, :message_invalid} =
             Messages.create_message(%{
               "conversation_id" => @conversation_id,
               "message_type" => "text",
               "body" => "Missing sender"
             })
  end

  test "create_message rejects DB-backed media messages without media_id" do
    assert {:error, :message_invalid} =
             Messages.create_message(%{
               "conversation_id" => @conversation_id,
               "sender_user_id" => @sender_user_id,
               "message_type" => "media",
               "caption" => "Missing media id"
             })
  end

  test "create_message persists a DB-backed media message through the configured store" do
    assert {:ok, message} =
             Messages.create_message(%{
               "conversation_id" => @conversation_id,
               "sender_user_id" => @sender_user_id,
               "message_type" => "media",
               "media_id" => "44444444-4444-4444-8444-444444444444"
             })

    assert message.conversation_id == @conversation_id
    assert message.sender_user_id == @sender_user_id
    assert message.message_type == "media"
    assert message.media_id == "44444444-4444-4444-8444-444444444444"
    assert message.caption == nil
    assert message.body == nil
    assert message.metadata == %{"media_id" => "44444444-4444-4444-8444-444444444444"}
  end

  test "create_message stores and returns DB-backed media caption" do
    assert {:ok, message} =
             Messages.create_message(%{
               "conversation_id" => @conversation_id,
               "sender_user_id" => @sender_user_id,
               "message_type" => "media",
               "media_id" => "55555555-5555-4555-8555-555555555555",
               "caption" => "Launch photo",
               "metadata" => %{"client_id" => "media-test"}
             })

    assert message.message_type == "media"
    assert message.media_id == "55555555-5555-4555-8555-555555555555"
    assert message.caption == "Launch photo"
    assert message.body == "Launch photo"

    assert message.metadata == %{
             "client_id" => "media-test",
             "media_id" => "55555555-5555-4555-8555-555555555555",
             "caption" => "Launch photo"
           }
  end

  test "create_message stores and returns DB-backed media object metadata" do
    assert {:ok, message} =
             Messages.create_message(%{
               "conversation_id" => @conversation_id,
               "sender_user_id" => @sender_user_id,
               "message_type" => "media",
               "media_id" => "66666666-6666-4666-8666-666666666666",
               "caption" => "Quarterly deck",
               "metadata" => %{
                 "object_key" =>
                   "media/#{@sender_user_id}/66666666-6666-4666-8666-666666666666/deck.pdf",
                 "filename" => "deck.pdf",
                 "content_type" => "application/pdf",
                 "size_bytes" => 123_456
               }
             })

    assert message.message_type == "media"
    assert message.media_id == "66666666-6666-4666-8666-666666666666"
    assert message.caption == "Quarterly deck"

    assert message.metadata == %{
             "media_id" => "66666666-6666-4666-8666-666666666666",
             "caption" => "Quarterly deck",
             "object_key" =>
               "media/#{@sender_user_id}/66666666-6666-4666-8666-666666666666/deck.pdf",
             "filename" => "deck.pdf",
             "content_type" => "application/pdf",
             "size_bytes" => "123456"
           }
  end

  test "create_message still accepts DB-backed media messages with only media_id" do
    assert {:ok, message} =
             Messages.create_message(%{
               "conversation_id" => @conversation_id,
               "sender_user_id" => @sender_user_id,
               "message_type" => "media",
               "media_id" => "77777777-7777-4777-8777-777777777777"
             })

    assert message.media_id == "77777777-7777-4777-8777-777777777777"
    assert message.body == nil
    assert message.caption == nil
    assert message.metadata == %{"media_id" => "77777777-7777-4777-8777-777777777777"}
  end

  test "update_message validates required DB-backed fields" do
    assert {:error, :message_invalid} =
             Messages.update_message(%{
               "conversation_id" => @conversation_id,
               "message_id" => "msg_123",
               "body" => "Missing actor"
             })

    assert {:error, :message_invalid} =
             Messages.update_message(%{
               "conversation_id" => @conversation_id,
               "message_id" => "msg_123",
               "actor_user_id" => @sender_user_id
             })
  end

  test "update_message edits a persisted message through in-memory store" do
    assert {:ok, created} =
             Messages.create_message(%{
               "conversation_id" => @conversation_id,
               "sender_user_id" => @sender_user_id,
               "message_type" => "text",
               "body" => "Original body"
             })

    assert {:ok, edited} =
             Messages.update_message(%{
               "conversation_id" => @conversation_id,
               "message_id" => created.message_id,
               "actor_user_id" => @sender_user_id,
               "body" => "Edited body"
             })

    assert edited.conversation_id == @conversation_id
    assert edited.message_id == created.message_id
    assert edited.body == "Edited body"
    assert edited.status == "edited"
    assert is_binary(edited.edited_at)

    assert {:ok, timeline} = Messages.list_messages(%{"conversation_id" => @conversation_id})
    assert [listed] = timeline.messages
    assert listed.body == "Edited body"
    assert listed.status == "edited"
  end

  test "delete_message soft deletes a persisted message through in-memory store" do
    assert {:ok, created} =
             Messages.create_message(%{
               "conversation_id" => @conversation_id,
               "sender_user_id" => @sender_user_id,
               "message_type" => "text",
               "body" => "Delete me"
             })

    assert {:ok, deleted} =
             Messages.delete_message(%{
               "conversation_id" => @conversation_id,
               "message_id" => created.message_id,
               "actor_user_id" => @sender_user_id
             })

    assert deleted.conversation_id == @conversation_id
    assert deleted.message_id == created.message_id
    assert deleted.deleted == true
    assert deleted.status == "deleted"
    assert is_binary(deleted.deleted_at)

    assert {:ok, timeline} = Messages.list_messages(%{"conversation_id" => @conversation_id})
    assert [listed] = timeline.messages
    assert listed.status == "deleted"
    assert is_binary(listed.deleted_at)
  end

  test "update_message rejects a non-author actor with message_forbidden" do
    assert {:ok, created} =
             Messages.create_message(%{
               "conversation_id" => @conversation_id,
               "sender_user_id" => @sender_user_id,
               "message_type" => "text",
               "body" => "Author body"
             })

    assert {:error, :message_forbidden} =
             Messages.update_message(%{
               "conversation_id" => @conversation_id,
               "message_id" => created.message_id,
               "actor_user_id" => @receipt_user_id,
               "body" => "Hijacked edit"
             })

    # Original message is unchanged.
    assert {:ok, timeline} = Messages.list_messages(%{"conversation_id" => @conversation_id})
    assert [listed] = timeline.messages
    assert listed.body == "Author body"
    assert listed.status == "active"
  end

  test "delete_message rejects a non-author actor with message_forbidden" do
    assert {:ok, created} =
             Messages.create_message(%{
               "conversation_id" => @conversation_id,
               "sender_user_id" => @sender_user_id,
               "message_type" => "text",
               "body" => "Author body"
             })

    assert {:error, :message_forbidden} =
             Messages.delete_message(%{
               "conversation_id" => @conversation_id,
               "message_id" => created.message_id,
               "actor_user_id" => @receipt_user_id
             })

    assert {:ok, timeline} = Messages.list_messages(%{"conversation_id" => @conversation_id})
    assert [listed] = timeline.messages
    assert listed.status == "active"
  end

  test "mark_delivered validates required DB-backed fields" do
    assert {:error, :message_invalid} =
             Receipts.mark_delivered(%{
               "conversation_id" => @conversation_id,
               "message_id" => "msg_123"
             })

    assert {:error, :message_invalid} =
             Receipts.mark_delivered(%{
               "conversation_id" => @conversation_id,
               "user_id" => @receipt_user_id
             })
  end

  test "mark_read validates required DB-backed fields" do
    assert {:error, :message_invalid} =
             Receipts.mark_read(%{
               "conversation_id" => @conversation_id,
               "message_id" => "msg_123"
             })

    assert {:error, :message_invalid} =
             Receipts.mark_read(%{
               "message_id" => "msg_123",
               "user_id" => @receipt_user_id
             })
  end

  test "mark_delivered records a receipt through in-memory store" do
    assert {:ok, delivered} =
             Receipts.mark_delivered(%{
               "conversation_id" => @conversation_id,
               "message_id" => "msg_123",
               "user_id" => @receipt_user_id
             })

    assert delivered.conversation_id == @conversation_id
    assert delivered.message_id == "msg_123"
    assert delivered.user_id == @receipt_user_id
    assert is_binary(delivered.delivered_at)
  end

  test "mark_read records a receipt through in-memory store" do
    assert {:ok, read} =
             Receipts.mark_read(%{
               "conversation_id" => @conversation_id,
               "message_id" => "msg_123",
               "user_id" => @receipt_user_id
             })

    assert read.conversation_id == @conversation_id
    assert read.message_id == "msg_123"
    assert read.user_id == @receipt_user_id
    assert is_binary(read.read_at)
  end

  test "mark_read after delivered keeps both in-memory receipt timestamps" do
    assert {:ok, delivered} =
             Receipts.mark_delivered(%{
               "conversation_id" => @conversation_id,
               "message_id" => "msg_123",
               "user_id" => @receipt_user_id
             })

    assert {:ok, read} =
             Receipts.mark_read(%{
               "conversation_id" => @conversation_id,
               "message_id" => "msg_123",
               "user_id" => @receipt_user_id
             })

    assert read.delivered_at == delivered.delivered_at
    assert is_binary(read.read_at)
  end

  test "default query-plan adapter documents that live Scylla storage is unavailable" do
    Application.put_env(:message_service, :message_store_adapter, MessageStore.QueryPlanAdapter)

    assert {:error, :message_store_unavailable} =
             Messages.create_message(%{
               "conversation_id" => @conversation_id,
               "sender_user_id" => @sender_user_id,
               "message_type" => "text",
               "body" => "Not written to live Scylla yet"
             })
  end

  test "scylla adapter executes insert and list plans through configured client" do
    Application.put_env(:message_service, :message_store_adapter, MessageStore.ScyllaAdapter)
    Application.put_env(:message_service, :scylla_client_adapter, MessageService.TestScyllaClient)

    assert {:ok, first} =
             Messages.create_message(%{
               "conversation_id" => @conversation_id,
               "sender_user_id" => @sender_user_id,
               "message_type" => "text",
               "body" => "First Scylla-plan message"
             })

    Process.sleep(2)

    assert {:ok, second} =
             Messages.create_message(%{
               "conversation_id" => @conversation_id,
               "sender_user_id" => @sender_user_id,
               "message_type" => "text",
               "body" => "Second Scylla-plan message"
             })

    assert {:ok, timeline} = Messages.list_messages(%{"conversation_id" => @conversation_id})

    assert Enum.map(timeline.messages, & &1.message_id) == [second.message_id, first.message_id]

    assert Enum.map(timeline.messages, & &1.body) == [
             "Second Scylla-plan message",
             "First Scylla-plan message"
           ]
  end

  test "scylla adapter can use shared configured client boundary" do
    Application.put_env(:message_service, :message_store_adapter, MessageStore.ScyllaAdapter)
    Application.delete_env(:message_service, :scylla_client_adapter)
    Application.put_env(:shared_infra, :scylla_client_adapter, MessageService.TestScyllaClient)

    assert {:ok, message} =
             Messages.create_message(%{
               "conversation_id" => @conversation_id,
               "sender_user_id" => @sender_user_id,
               "message_type" => "text",
               "body" => "Shared client boundary"
             })

    assert message.body == "Shared client boundary"
  end

  test "scylla adapter executes update and delete plans through configured client" do
    Application.put_env(:message_service, :message_store_adapter, MessageStore.ScyllaAdapter)
    Application.put_env(:message_service, :scylla_client_adapter, MessageService.TestScyllaClient)

    assert {:ok, created} =
             Messages.create_message(%{
               "conversation_id" => @conversation_id,
               "sender_user_id" => @sender_user_id,
               "message_type" => "text",
               "body" => "Original Scylla-plan body"
             })

    assert {:ok, edited} =
             Messages.update_message(%{
               "conversation_id" => @conversation_id,
               "message_id" => created.message_id,
               "actor_user_id" => @sender_user_id,
               "body" => "Edited Scylla-plan body"
             })

    assert edited.status == "edited"
    assert edited.body == "Edited Scylla-plan body"

    assert {:ok, deleted} =
             Messages.delete_message(%{
               "conversation_id" => @conversation_id,
               "message_id" => created.message_id,
               "actor_user_id" => @sender_user_id
             })

    assert deleted.status == "deleted"
    assert deleted.deleted == true

    assert {:ok, timeline} = Messages.list_messages(%{"conversation_id" => @conversation_id})
    assert [listed] = timeline.messages
    assert listed.status == "deleted"
  end

  test "scylla adapter executes receipt plans through configured client" do
    Application.put_env(:message_service, :message_store_adapter, MessageStore.ScyllaAdapter)
    Application.put_env(:message_service, :scylla_client_adapter, MessageService.TestScyllaClient)

    assert {:ok, delivered} =
             Receipts.mark_delivered(%{
               "conversation_id" => @conversation_id,
               "message_id" => "msg_123",
               "user_id" => @receipt_user_id
             })

    assert delivered.user_id == @receipt_user_id
    assert is_binary(delivered.delivered_at)

    assert {:ok, read} =
             Receipts.mark_read(%{
               "conversation_id" => @conversation_id,
               "message_id" => "msg_123",
               "user_id" => @receipt_user_id
             })

    assert read.user_id == @receipt_user_id
    assert is_binary(read.read_at)
  end

  defp start_in_memory_store! do
    case MessageStore.InMemoryAdapter.start_link() do
      {:ok, pid} ->
        Process.unlink(pid)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end

  defp start_test_scylla_client! do
    case MessageService.TestScyllaClient.start_link() do
      {:ok, pid} ->
        Process.unlink(pid)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end
end
