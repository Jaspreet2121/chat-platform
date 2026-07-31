defmodule MessageService.Persistence.MessageReceipts do
  @moduledoc """
  Query plans for `message_receipts_by_conversation`.
  """

  alias MessageService.Persistence.Attrs
  alias MessageService.Persistence.QueryPlan
  alias MessageService.Persistence.ScyllaCodec

  @table "message_receipts_by_conversation"

  # STATUS-SPECIFIC COLUMN WRITE (003): delivered writes delivered_at, read writes read_at. CQL
  # upserts merge unset columns, so a delivered->read upgrade keeps BOTH timestamps in the one row —
  # the Postgres receipts semantics message_info's wire shape depends on. Writing (status, updated_at,
  # <one timestamp>) per call is what makes that merge happen; a single generic timestamp column
  # would lose delivered_at on the read upsert (the C4 contact finding that added 003).
  def upsert_receipt_plan(attrs) do
    status = Attrs.get(attrs, :status)
    timestamp_column = if status == "read", do: "read_at", else: "delivered_at"

    QueryPlan.new(
      :upsert_message_receipt,
      @table,
      """
      INSERT INTO message_receipts_by_conversation (
        conversation_id, message_id, user_id, status, updated_at, #{timestamp_column}
      ) VALUES (?, ?, ?, ?, ?, ?)
      """,
      [
        ScyllaCodec.encode_uuid(Attrs.get(attrs, :conversation_id)),
        ScyllaCodec.encode_uuid(Attrs.get(attrs, :message_id)),
        ScyllaCodec.encode_uuid(Attrs.get(attrs, :user_id)),
        status,
        ScyllaCodec.encode_timestamp(Attrs.get(attrs, :updated_at)),
        ScyllaCodec.encode_timestamp(Attrs.get(attrs, :updated_at))
      ]
    )
  end

  def list_for_message_plan(attrs) do
    QueryPlan.new(
      :list_message_receipts,
      @table,
      """
      SELECT conversation_id, message_id, user_id, status, updated_at, delivered_at, read_at
      FROM message_receipts_by_conversation
      WHERE conversation_id = ? AND message_id = ?
      """,
      [
        ScyllaCodec.encode_uuid(Attrs.get(attrs, :conversation_id)),
        ScyllaCodec.encode_uuid(Attrs.get(attrs, :message_id))
      ]
    )
  end
end
