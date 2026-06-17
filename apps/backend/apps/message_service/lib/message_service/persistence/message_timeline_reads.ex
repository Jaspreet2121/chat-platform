defmodule MessageService.Persistence.MessageTimelineReads do
  @moduledoc """
  Query plans for reads from `messages_by_conversation`.
  """

  alias MessageService.Persistence.Attrs
  alias MessageService.Persistence.QueryPlan

  @table "messages_by_conversation"

  def list_recent_plan(attrs) do
    QueryPlan.new(
      :list_recent_messages,
      @table,
      """
      SELECT conversation_id, bucket_date, message_id, sender_user_id,
        message_type, body, media_id, reply_to_message_id, status, metadata,
        created_at, edited_at, deleted_at
      FROM messages_by_conversation
      WHERE conversation_id = ? AND bucket_date = ?
      LIMIT ?
      """,
      [
        Attrs.get(attrs, :conversation_id),
        Attrs.get(attrs, :bucket_date),
        Attrs.get(attrs, :limit)
      ]
    )
  end

  def list_before_plan(attrs) do
    QueryPlan.new(
      :list_messages_before,
      @table,
      """
      SELECT conversation_id, bucket_date, message_id, sender_user_id,
        message_type, body, media_id, reply_to_message_id, status, metadata,
        created_at, edited_at, deleted_at
      FROM messages_by_conversation
      WHERE conversation_id = ? AND bucket_date = ? AND message_id < ?
      LIMIT ?
      """,
      [
        Attrs.get(attrs, :conversation_id),
        Attrs.get(attrs, :bucket_date),
        Attrs.get(attrs, :before_message_id),
        Attrs.get(attrs, :limit)
      ]
    )
  end
end
