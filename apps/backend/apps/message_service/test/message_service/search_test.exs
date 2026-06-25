defmodule MessageService.SearchTest do
  @moduledoc """
  Message search at the store boundary (Docker-free, in-memory adapter). The load-bearing test is
  PRIVACY SCOPING: a message in a conversation the caller is NOT a participant of must never appear
  in their results. Also covers case-insensitivity, deleted-exclusion, and the min-length guard.
  """
  use ExUnit.Case, async: false

  alias MessageService.Messages
  alias MessageService.MessageStore
  alias MessageService.Search

  @user_a "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  @user_b "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  @conv_mine "11111111-1111-4111-8111-111111111111"
  @conv_theirs "22222222-2222-4222-8222-222222222222"

  setup do
    previous = %{
      persistence: Application.get_env(:message_service, :message_persistence, false),
      adapter:
        Application.get_env(
          :message_service,
          :message_store_adapter,
          MessageStore.QueryPlanAdapter
        )
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

    # user_a participates ONLY in @conv_mine. user_b owns @conv_theirs.
    MessageStore.InMemoryAdapter.seed_participant(@conv_mine, @user_a)
    MessageStore.InMemoryAdapter.seed_participant(@conv_theirs, @user_b)

    {:ok, mine} = create(@conv_mine, @user_a, "hello from my conversation")
    {:ok, theirs} = create(@conv_theirs, @user_b, "hello from a conversation I am not in")

    %{mine: mine.message_id, theirs: theirs.message_id}
  end

  test "results are scoped to the caller's conversations (not-a-member message excluded)", %{
    mine: mine,
    theirs: theirs
  } do
    {:ok, result} = Search.search_messages(%{"user_id" => @user_a, "query" => "hello"})

    ids = Enum.map(result.messages, & &1.message_id)
    assert mine in ids
    refute theirs in ids
    assert result.query == "hello"
  end

  test "search is case-insensitive", %{mine: mine} do
    {:ok, result} = Search.search_messages(%{"user_id" => @user_a, "query" => "HELLO"})
    assert Enum.map(result.messages, & &1.message_id) == [mine]
  end

  test "deleted messages are excluded", %{} do
    {:ok, doomed} = create(@conv_mine, @user_a, "hello soon to be deleted")

    {:ok, _} =
      Messages.delete_message(%{
        "conversation_id" => @conv_mine,
        "message_id" => doomed.message_id,
        "actor_user_id" => @user_a
      })

    {:ok, result} = Search.search_messages(%{"user_id" => @user_a, "query" => "deleted"})
    refute doomed.message_id in Enum.map(result.messages, & &1.message_id)
  end

  test "a query shorter than the minimum is rejected", %{} do
    assert {:error, :query_too_short} =
             Search.search_messages(%{"user_id" => @user_a, "query" => "h"})
  end

  defp create(conversation_id, sender_user_id, body) do
    Messages.create_message(%{
      "conversation_id" => conversation_id,
      "sender_user_id" => sender_user_id,
      "message_type" => "text",
      "body" => body
    })
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
