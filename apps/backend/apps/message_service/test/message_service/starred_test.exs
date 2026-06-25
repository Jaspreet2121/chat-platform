defmodule MessageService.StarredTest do
  @moduledoc """
  Star/bookmark at the store boundary (Docker-free, in-memory adapter): star → surfaced as
  `is_starred: true` on the timeline for the viewer AND listed in the Starred view; idempotent
  (starring twice keeps one); unstar clears both. is_starred is per-viewer (private).
  """
  use ExUnit.Case, async: false

  alias MessageService.Messages
  alias MessageService.MessageStore
  alias MessageService.Stars

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
        "body" => "star me"
      })

    %{message_id: created.message_id}
  end

  test "star surfaces is_starred on the timeline (per viewer) and lists in Starred", %{
    message_id: message_id
  } do
    {:ok, result} = star(message_id, @other_user_id)
    assert result == %{message_id: message_id, is_starred: true}

    # is_starred is scoped to the viewer: true for the starrer, false for everyone else.
    assert list_message(message_id, @other_user_id).is_starred == true
    assert list_message(message_id, @sender_user_id).is_starred == false

    # Appears in the starrer's Starred view, with is_starred set.
    {:ok, starred} = Stars.list_starred(%{"user_id" => @other_user_id})
    assert [%{message_id: ^message_id, is_starred: true}] = starred.messages

    # ...and NOT in another user's Starred view (private).
    {:ok, other} = Stars.list_starred(%{"user_id" => @sender_user_id})
    assert other.messages == []
  end

  test "starring is idempotent (twice → one entry)", %{message_id: message_id} do
    {:ok, _} = star(message_id, @other_user_id)
    {:ok, _} = star(message_id, @other_user_id)

    {:ok, starred} = Stars.list_starred(%{"user_id" => @other_user_id})
    assert length(starred.messages) == 1
  end

  test "unstar clears it from the timeline flag and the Starred view", %{message_id: message_id} do
    {:ok, _} = star(message_id, @other_user_id)

    {:ok, result} =
      Stars.unstar_message(%{"user_id" => @other_user_id, "message_id" => message_id})

    assert result == %{message_id: message_id, is_starred: false}

    assert list_message(message_id, @other_user_id).is_starred == false
    {:ok, starred} = Stars.list_starred(%{"user_id" => @other_user_id})
    assert starred.messages == []
  end

  defp star(message_id, user_id) do
    Stars.star_message(%{
      "user_id" => user_id,
      "message_id" => message_id,
      "conversation_id" => @conversation_id
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
