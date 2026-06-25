defmodule MessageService.ReactionProjectionTest do
  @moduledoc """
  Proves the WhatsApp reaction model end-to-end at the store boundary (Docker-free, in-memory adapter):
  add → surfaced on load as `reactions: [%{emoji, count}]` + the viewer's `my_reaction`; one-per-user
  (a second emoji from the same user CHANGES, never stacks); cross-user counts aggregate; remove clears.
  """
  use ExUnit.Case, async: false

  alias MessageService.Messages
  alias MessageService.MessageStore
  alias MessageService.Reactions

  @conversation_id "11111111-1111-4111-8111-111111111111"
  @sender_user_id "22222222-2222-4222-8222-222222222222"
  @other_user_id "33333333-3333-4333-8333-333333333333"

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

    {:ok, created} =
      Messages.create_message(%{
        "conversation_id" => @conversation_id,
        "sender_user_id" => @sender_user_id,
        "message_type" => "text",
        "body" => "hi"
      })

    %{message_id: created.message_id}
  end

  test "fresh message surfaces empty reaction aggregate on load", %{message_id: message_id} do
    msg = list_message(message_id, @sender_user_id)
    assert msg.reactions == []
    assert msg.my_reaction == nil
  end

  test "add surfaces reactions[] + my_reaction durably on reload", %{message_id: message_id} do
    {:ok, aggregate} =
      Reactions.add_reaction(%{
        "conversation_id" => @conversation_id,
        "message_id" => message_id,
        "user_id" => @other_user_id,
        "emoji" => "👍"
      })

    # The op echoes the new aggregate (what the gateway/realtime broadcast).
    assert aggregate.message_id == message_id
    assert aggregate.reactions == [%{emoji: "👍", count: 1}]

    # And it survives a fresh list load, with my_reaction scoped to the viewer.
    msg = list_message(message_id, @other_user_id)
    assert msg.reactions == [%{emoji: "👍", count: 1}]
    assert msg.my_reaction == "👍"

    # A different viewer sees the count but no my_reaction of their own.
    other_view = list_message(message_id, @sender_user_id)
    assert other_view.reactions == [%{emoji: "👍", count: 1}]
    assert other_view.my_reaction == nil
  end

  test "same user re-reacting CHANGES the emoji (one per user, never stacks)", %{
    message_id: message_id
  } do
    {:ok, _} = react(message_id, @other_user_id, "👍")
    {:ok, aggregate} = react(message_id, @other_user_id, "❤️")

    assert aggregate.reactions == [%{emoji: "❤️", count: 1}]

    msg = list_message(message_id, @other_user_id)
    assert msg.reactions == [%{emoji: "❤️", count: 1}]
    assert msg.my_reaction == "❤️"
  end

  test "cross-user reactions aggregate into per-emoji counts (sorted by count desc)", %{
    message_id: message_id
  } do
    {:ok, _} = react(message_id, @sender_user_id, "😂")
    {:ok, _} = react(message_id, @other_user_id, "😂")

    msg = list_message(message_id, @sender_user_id)
    assert msg.reactions == [%{emoji: "😂", count: 2}]
    assert msg.my_reaction == "😂"
  end

  test "remove clears the caller's reaction", %{message_id: message_id} do
    {:ok, _} = react(message_id, @other_user_id, "🙏")

    {:ok, aggregate} =
      Reactions.remove_reaction(%{"message_id" => message_id, "user_id" => @other_user_id})

    assert aggregate.reactions == []

    msg = list_message(message_id, @other_user_id)
    assert msg.reactions == []
    assert msg.my_reaction == nil
  end

  defp react(message_id, user_id, emoji) do
    Reactions.add_reaction(%{
      "conversation_id" => @conversation_id,
      "message_id" => message_id,
      "user_id" => user_id,
      "emoji" => emoji
    })
  end

  defp list_message(message_id, viewer_user_id) do
    {:ok, listing} =
      Messages.list_messages(%{
        "conversation_id" => @conversation_id,
        "viewer_user_id" => viewer_user_id
      })

    Enum.find(listing.messages, &(&1.message_id == message_id))
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
