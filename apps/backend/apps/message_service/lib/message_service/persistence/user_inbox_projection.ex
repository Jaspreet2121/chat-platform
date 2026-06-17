defmodule MessageService.Persistence.UserInboxProjection do
  @moduledoc """
  Query plans for `messages_by_user_inbox`.
  """

  alias MessageService.Persistence.Attrs
  alias MessageService.Persistence.QueryPlan

  @table "messages_by_user_inbox"

  def upsert_inbox_entry_plan(attrs) do
    QueryPlan.new(
      :upsert_user_inbox_entry,
      @table,
      """
      INSERT INTO messages_by_user_inbox (
        user_id, last_message_at, conversation_id, last_message_id,
        last_message_preview, unread_count
      ) VALUES (?, ?, ?, ?, ?, ?)
      """,
      [
        Attrs.get(attrs, :user_id),
        Attrs.get(attrs, :last_message_at),
        Attrs.get(attrs, :conversation_id),
        Attrs.get(attrs, :last_message_id),
        Attrs.get(attrs, :last_message_preview),
        Attrs.get(attrs, :unread_count)
      ]
    )
  end

  def list_user_inbox_plan(attrs) do
    QueryPlan.new(
      :list_user_inbox,
      @table,
      """
      SELECT user_id, last_message_at, conversation_id, last_message_id,
        last_message_preview, unread_count
      FROM messages_by_user_inbox
      WHERE user_id = ?
      LIMIT ?
      """,
      [
        Attrs.get(attrs, :user_id),
        Attrs.get(attrs, :limit)
      ]
    )
  end
end
