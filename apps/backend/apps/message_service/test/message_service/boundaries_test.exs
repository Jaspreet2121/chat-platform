defmodule MessageService.BoundariesTest do
  use ExUnit.Case, async: true

  test "Messages boundary sends placeholder message" do
    assert {:ok, message} =
             MessageService.Messages.send_message(%{
               "conversation_id" => "conv_123",
               "message_type" => "text",
               "body" => "Hello"
             })

    assert message.conversation_id == "conv_123"
    assert message.message_id == "msg_placeholder"
    assert message.body == "Hello"
  end

  test "Messages boundary edits and deletes placeholder message" do
    assert {:ok, edited} =
             MessageService.Messages.edit_message(%{
               "conversation_id" => "conv_123",
               "message_id" => "msg_123",
               "body" => "Hello edited"
             })

    assert edited.status == "edited"
    assert edited.body == "Hello edited"

    assert {:ok, deleted} =
             MessageService.Messages.delete_message(%{
               "conversation_id" => "conv_123",
               "message_id" => "msg_123"
             })

    assert deleted.status == "deleted"
  end

  test "Timeline boundary lists placeholder messages" do
    assert {:ok, timeline} =
             MessageService.Timeline.list_messages(%{
               "conversation_id" => "conv_123"
             })

    assert timeline.conversation_id == "conv_123"
    assert [%{message_id: "msg_placeholder"}] = timeline.messages
  end

  test "Receipts boundary marks read and delivered placeholders" do
    assert {:ok, read} =
             MessageService.Receipts.mark_read(%{
               "conversation_id" => "conv_123",
               "message_id" => "msg_123"
             })

    assert read.read_by_user_id == "user_placeholder"

    assert {:ok, delivered} =
             MessageService.Receipts.mark_delivered(%{
               "conversation_id" => "conv_123",
               "message_id" => "msg_123"
             })

    assert delivered.delivered_to_user_id == "user_placeholder"
  end

  test "Reactions and Permissions boundaries return placeholders" do
    assert {:ok, reaction} = MessageService.Reactions.add_reaction(%{"reaction" => "heart"})
    assert reaction.reaction == "heart"

    assert {:ok, permission} = MessageService.Permissions.authorize(%{})
    assert permission.authorized == true
  end
end
