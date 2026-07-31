defmodule MessageService.PersistenceQueryPlansTest do
  use ExUnit.Case, async: true

  alias MessageService.Persistence.MessageReactions
  alias MessageService.Persistence.MessageReceipts
  alias MessageService.Persistence.MessageTimelineReads
  alias MessageService.Persistence.MessageTimelineWrites
  alias MessageService.Persistence.UserInboxProjection

  @conversation_id "11111111-1111-1111-1111-111111111111"
  @bucket_date "2026-06-17"
  # What the codec puts ON THE WIRE for that bucket — CQL `date` wants %Date{}, not an ISO string.
  @bucket_date_wire ~D[2026-06-17]
  @message_id "22222222-2222-1222-8222-222222222222"
  @sender_user_id "33333333-3333-3333-3333-333333333333"
  @user_id "44444444-4444-4444-4444-444444444444"
  @now ~U[2026-06-17 10:15:00Z]

  test "message timeline write plan targets messages_by_conversation with ordered params" do
    plan =
      MessageTimelineWrites.insert_message_plan(%{
        conversation_id: @conversation_id,
        bucket_date: @bucket_date,
        message_id: @message_id,
        sender_user_id: @sender_user_id,
        message_type: "text",
        body: "Hello",
        media_id: nil,
        reply_to_message_id: nil,
        status: "active",
        metadata: %{},
        created_at: @now,
        edited_at: nil,
        deleted_at: nil
      })

    assert plan.operation == :insert_message
    assert plan.table == "messages_by_conversation"
    assert_placeholder_count(plan.statement, 13)
    refute String.contains?(plan.statement, "Hello")

    assert Enum.take(plan.params, 6) == [
             @conversation_id,
             @bucket_date_wire,
             @message_id,
             @sender_user_id,
             "text",
             "Hello"
           ]
  end

  test "message timeline edit and delete plans are parameterized" do
    edit_plan =
      MessageTimelineWrites.mark_edited_plan(%{
        "conversation_id" => @conversation_id,
        "bucket_date" => @bucket_date,
        "message_id" => @message_id,
        "body" => "Edited",
        "edited_at" => @now
      })

    delete_plan =
      MessageTimelineWrites.mark_deleted_plan(%{
        conversation_id: @conversation_id,
        bucket_date: @bucket_date,
        message_id: @message_id,
        deleted_at: @now
      })

    assert edit_plan.operation == :mark_message_edited
    assert_placeholder_count(edit_plan.statement, 6)

    assert edit_plan.params == [
             "Edited",
             "edited",
             @now,
             @conversation_id,
             @bucket_date_wire,
             @message_id
           ]

    assert delete_plan.operation == :mark_message_deleted
    assert_placeholder_count(delete_plan.statement, 5)

    assert delete_plan.params == [
             "deleted",
             @now,
             @conversation_id,
             @bucket_date_wire,
             @message_id
           ]
  end

  test "message timeline read plans target partition keys and limits" do
    recent_plan =
      MessageTimelineReads.list_recent_plan(%{
        conversation_id: @conversation_id,
        bucket_date: @bucket_date,
        limit: 50
      })

    before_plan =
      MessageTimelineReads.list_before_plan(%{
        conversation_id: @conversation_id,
        bucket_date: @bucket_date,
        before_message_id: @message_id,
        limit: 25
      })

    assert recent_plan.table == "messages_by_conversation"
    assert_placeholder_count(recent_plan.statement, 3)
    assert recent_plan.params == [@conversation_id, @bucket_date_wire, 50]

    assert before_plan.operation == :list_messages_before
    assert_placeholder_count(before_plan.statement, 4)
    assert before_plan.params == [@conversation_id, @bucket_date_wire, @message_id, 25]
  end

  test "receipt plans target message_receipts_by_conversation" do
    upsert_plan =
      MessageReceipts.upsert_receipt_plan(%{
        conversation_id: @conversation_id,
        message_id: @message_id,
        user_id: @user_id,
        status: "read",
        updated_at: @now
      })

    list_plan =
      MessageReceipts.list_for_message_plan(%{
        conversation_id: @conversation_id,
        message_id: @message_id
      })

    assert upsert_plan.table == "message_receipts_by_conversation"
    assert_placeholder_count(upsert_plan.statement, 5)
    assert upsert_plan.params == [@conversation_id, @message_id, @user_id, "read", @now]

    assert list_plan.params == [@conversation_id, @message_id]
    assert_placeholder_count(list_plan.statement, 2)
  end

  test "reaction plans target message_reactions_by_message" do
    upsert_plan =
      MessageReactions.upsert_reaction_plan(%{
        conversation_id: @conversation_id,
        message_id: @message_id,
        user_id: @user_id,
        reaction: "heart",
        created_at: @now
      })

    delete_plan =
      MessageReactions.delete_reaction_plan(%{
        conversation_id: @conversation_id,
        message_id: @message_id,
        user_id: @user_id
      })

    list_plan =
      MessageReactions.list_for_message_plan(%{
        conversation_id: @conversation_id,
        message_id: @message_id
      })

    assert upsert_plan.table == "message_reactions_by_message"
    assert_placeholder_count(upsert_plan.statement, 5)
    assert upsert_plan.params == [@conversation_id, @message_id, @user_id, "heart", @now]

    assert delete_plan.params == [@conversation_id, @message_id, @user_id]
    assert_placeholder_count(delete_plan.statement, 3)

    assert list_plan.params == [@conversation_id, @message_id]
    assert_placeholder_count(list_plan.statement, 2)
  end

  test "user inbox projection plans target messages_by_user_inbox" do
    upsert_plan =
      UserInboxProjection.upsert_inbox_entry_plan(%{
        user_id: @user_id,
        last_message_at: @now,
        conversation_id: @conversation_id,
        last_message_id: @message_id,
        last_message_preview: "Hello",
        unread_count: 3
      })

    list_plan = UserInboxProjection.list_user_inbox_plan(%{user_id: @user_id, limit: 20})

    assert upsert_plan.table == "messages_by_user_inbox"
    assert_placeholder_count(upsert_plan.statement, 6)
    assert upsert_plan.params == [@user_id, @now, @conversation_id, @message_id, "Hello", 3]

    assert list_plan.operation == :list_user_inbox
    assert list_plan.params == [@user_id, 20]
    assert_placeholder_count(list_plan.statement, 2)
  end

  defp assert_placeholder_count(statement, count) do
    assert statement |> String.graphemes() |> Enum.count(&(&1 == "?")) == count
  end
end
