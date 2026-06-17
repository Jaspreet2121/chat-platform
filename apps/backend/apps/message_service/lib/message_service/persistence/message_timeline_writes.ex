defmodule MessageService.Persistence.MessageTimelineWrites do
  @moduledoc """
  Query plans for writes to `messages_by_conversation`.
  """

  alias MessageService.Persistence.Attrs
  alias MessageService.Persistence.QueryPlan

  @table "messages_by_conversation"

  def insert_message_plan(attrs) do
    QueryPlan.new(
      :insert_message,
      @table,
      """
      INSERT INTO messages_by_conversation (
        conversation_id, bucket_date, message_id, sender_user_id, message_type,
        body, media_id, reply_to_message_id, status, metadata, created_at,
        edited_at, deleted_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        Attrs.get(attrs, :conversation_id),
        Attrs.get(attrs, :bucket_date),
        Attrs.get(attrs, :message_id),
        Attrs.get(attrs, :sender_user_id),
        Attrs.get(attrs, :message_type),
        Attrs.get(attrs, :body),
        Attrs.get(attrs, :media_id),
        Attrs.get(attrs, :reply_to_message_id),
        Attrs.get(attrs, :status),
        Attrs.get(attrs, :metadata),
        Attrs.get(attrs, :created_at),
        Attrs.get(attrs, :edited_at),
        Attrs.get(attrs, :deleted_at)
      ]
    )
  end

  def mark_edited_plan(attrs) do
    QueryPlan.new(
      :mark_message_edited,
      @table,
      """
      UPDATE messages_by_conversation
      SET body = ?, status = ?, edited_at = ?
      WHERE conversation_id = ? AND bucket_date = ? AND message_id = ?
      """,
      [
        Attrs.get(attrs, :body),
        "edited",
        Attrs.get(attrs, :edited_at),
        Attrs.get(attrs, :conversation_id),
        Attrs.get(attrs, :bucket_date),
        Attrs.get(attrs, :message_id)
      ]
    )
  end

  def mark_deleted_plan(attrs) do
    QueryPlan.new(
      :mark_message_deleted,
      @table,
      """
      UPDATE messages_by_conversation
      SET status = ?, deleted_at = ?
      WHERE conversation_id = ? AND bucket_date = ? AND message_id = ?
      """,
      [
        "deleted",
        Attrs.get(attrs, :deleted_at),
        Attrs.get(attrs, :conversation_id),
        Attrs.get(attrs, :bucket_date),
        Attrs.get(attrs, :message_id)
      ]
    )
  end
end
