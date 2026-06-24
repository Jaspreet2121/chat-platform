defmodule MessageService.ReceiptProjectionTest do
  @moduledoc """
  Proves that `list_messages` surfaces per-message read/delivered receipt aggregates on load (so the
  client can render durable read ticks). Docker-free: uses the in-memory store adapter.
  """
  use ExUnit.Case, async: false

  alias MessageService.Messages
  alias MessageService.MessageStore
  alias MessageService.Receipts

  @conversation_id "11111111-1111-4111-8111-111111111111"
  @sender_user_id "22222222-2222-4222-8222-222222222222"
  @reader_user_id "33333333-3333-4333-8333-333333333333"

  setup do
    previous = %{
      persistence: Application.get_env(:message_service, :message_persistence, false),
      adapter:
        Application.get_env(:message_service, :message_store_adapter, MessageStore.QueryPlanAdapter)
    }

    Application.put_env(:message_service, :message_persistence, true)
    Application.put_env(:message_service, :message_store_adapter, MessageStore.InMemoryAdapter)
    start_in_memory_store!()
    MessageStore.InMemoryAdapter.reset()

    on_exit(fn ->
      MessageStore.InMemoryAdapter.reset()
      Application.put_env(:message_service, :message_persistence, previous.persistence)
      Application.put_env(:message_service, :message_store_adapter, previous.adapter)
    end)

    :ok
  end

  test "list surfaces read_by_count/delivered_by_count, and a read mark flips read_by_count" do
    {:ok, created} =
      Messages.create_message(%{
        "conversation_id" => @conversation_id,
        "sender_user_id" => @sender_user_id,
        "message_type" => "text",
        "body" => "hi"
      })

    message_id = created.message_id

    # Fresh message: surfaced on load with zeroed receipt aggregates.
    {:ok, before} = Messages.list_messages(%{"conversation_id" => @conversation_id})
    msg = Enum.find(before.messages, &(&1.message_id == message_id))
    assert msg.read_by_count == 0
    assert msg.delivered_by_count == 0

    # The other participant reads it.
    {:ok, _receipt} =
      Receipts.mark_read(%{
        "conversation_id" => @conversation_id,
        "message_id" => message_id,
        "user_id" => @reader_user_id
      })

    # Re-loading the timeline reflects the read durably (this is what makes the tick survive reload).
    {:ok, after_read} = Messages.list_messages(%{"conversation_id" => @conversation_id})
    read_msg = Enum.find(after_read.messages, &(&1.message_id == message_id))
    assert read_msg.read_by_count == 1
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
end
