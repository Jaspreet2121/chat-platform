defmodule MessageService.Persistence.MessageReceipts do
  @moduledoc """
  Query plans for `message_receipts_by_conversation`.
  """

  alias MessageService.Persistence.Attrs
  alias MessageService.Persistence.QueryPlan

  @table "message_receipts_by_conversation"

  def upsert_receipt_plan(attrs) do
    QueryPlan.new(
      :upsert_message_receipt,
      @table,
      """
      INSERT INTO message_receipts_by_conversation (
        conversation_id, message_id, user_id, status, updated_at
      ) VALUES (?, ?, ?, ?, ?)
      """,
      [
        Attrs.get(attrs, :conversation_id),
        Attrs.get(attrs, :message_id),
        Attrs.get(attrs, :user_id),
        Attrs.get(attrs, :status),
        Attrs.get(attrs, :updated_at)
      ]
    )
  end

  def list_for_message_plan(attrs) do
    QueryPlan.new(
      :list_message_receipts,
      @table,
      """
      SELECT conversation_id, message_id, user_id, status, updated_at
      FROM message_receipts_by_conversation
      WHERE conversation_id = ? AND message_id = ?
      """,
      [
        Attrs.get(attrs, :conversation_id),
        Attrs.get(attrs, :message_id)
      ]
    )
  end
end
