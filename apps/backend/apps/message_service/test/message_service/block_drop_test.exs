defmodule MessageService.BlockDropTest do
  @moduledoc """
  The block-drop synthesize path: a message flagged `delivery_disposition: "drop"` (set SERVER-SIDE by the
  send gate for a DIRECT chat whose recipient blocked the sender) returns a CANONICAL message to the sender
  WITHOUT persisting or publishing. The ack must be a full §4.1 message — a partial/absent ack would leave the
  sender's outbox stuck PENDING, which itself reveals the block. Docker-free: synthesize never touches the
  store, so this runs with persistence OFF.
  """
  use ExUnit.Case, async: false

  alias MessageService.Messages

  @conv "11111111-1111-4111-8111-111111111111"
  @sender "22222222-2222-4222-8222-222222222222"

  defp drop(attrs) do
    Messages.create_message(Map.merge(%{"delivery_disposition" => "drop"}, attrs))
  end

  test "a dropped TEXT message returns a canonical, well-formed message (no store required)" do
    assert {:ok, msg} =
             drop(%{
               "conversation_id" => @conv,
               "sender_user_id" => @sender,
               "message_type" => "text",
               "body" => "hi"
             })

    # Every field the Android outbox needs to replace its PENDING row (contract §4.1).
    assert msg.conversation_id == @conv
    assert msg.sender_user_id == @sender
    assert msg.message_type == "text"
    assert msg.body == "hi"
    assert msg.status == "active"
    assert is_binary(msg.message_id) and msg.message_id != ""
    assert is_binary(msg.created_at)
    assert msg.read_by_count == 0
    assert msg.delivered_by_count == 0
    assert msg.reactions == []
    assert msg.my_reaction == nil
    assert msg.is_starred == false
  end

  test "each dropped message gets a DISTINCT message_id (a real timeuuid — just no row behind it)" do
    id = fn ->
      {:ok, m} =
        drop(%{
          "conversation_id" => @conv,
          "sender_user_id" => @sender,
          "message_type" => "text",
          "body" => "x"
        })

      m.message_id
    end

    assert id.() != id.()
  end

  test "a dropped MEDIA message carries media_id + caption in the canonical shape" do
    assert {:ok, msg} =
             drop(%{
               "conversation_id" => @conv,
               "sender_user_id" => @sender,
               "message_type" => "media",
               "media_id" => "media-1",
               "caption" => "look"
             })

    assert msg.message_type == "media"
    assert msg.media_id == "media-1"
    assert msg.caption == "look"
  end
end
