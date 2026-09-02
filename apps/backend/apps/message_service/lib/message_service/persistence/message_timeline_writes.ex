defmodule MessageService.Persistence.MessageTimelineWrites do
  @moduledoc """
  Query plans for writes to `messages_by_conversation`.
  """

  alias MessageService.Persistence.Attrs
  alias MessageService.Persistence.QueryPlan
  alias MessageService.Persistence.ScyllaCodec

  @table "messages_by_conversation"

  def insert_message_plan(attrs) do
    QueryPlan.new(
      :insert_message,
      @table,
      """
      INSERT INTO messages_by_conversation (
        conversation_id, bucket_date, message_id, sender_user_id, message_type,
        body, media_id, reply_to_message_id, status, metadata, view_once, created_at,
        edited_at, deleted_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        ScyllaCodec.encode_uuid(Attrs.get(attrs, :conversation_id)),
        ScyllaCodec.encode_date(Attrs.get(attrs, :bucket_date)),
        ScyllaCodec.encode_uuid(Attrs.get(attrs, :message_id)),
        ScyllaCodec.encode_uuid(Attrs.get(attrs, :sender_user_id)),
        Attrs.get(attrs, :message_type),
        Attrs.get(attrs, :body),
        ScyllaCodec.encode_uuid(Attrs.get(attrs, :media_id)),
        ScyllaCodec.encode_uuid(Attrs.get(attrs, :reply_to_message_id)),
        Attrs.get(attrs, :status),
        ScyllaCodec.encode_metadata(Attrs.get(attrs, :metadata)),
        # A NATIVE BOOLEAN, never a metadata entry. metadata is map<text,text> here, so routing the
        # flag through it would store the STRING "true" while Postgres stores a real boolean — two
        # stores disagreeing about a value that gates media access. Defaulted to false so a caller
        # that omits it writes the same thing Postgres's column default writes.
        Attrs.get(attrs, :view_once) || false,
        ScyllaCodec.encode_timestamp(Attrs.get(attrs, :created_at)),
        ScyllaCodec.encode_timestamp(Attrs.get(attrs, :edited_at)),
        ScyllaCodec.encode_timestamp(Attrs.get(attrs, :deleted_at))
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
        ScyllaCodec.encode_timestamp(Attrs.get(attrs, :edited_at)),
        ScyllaCodec.encode_uuid(Attrs.get(attrs, :conversation_id)),
        ScyllaCodec.encode_date(Attrs.get(attrs, :bucket_date)),
        ScyllaCodec.encode_uuid(Attrs.get(attrs, :message_id))
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
        ScyllaCodec.encode_timestamp(Attrs.get(attrs, :deleted_at)),
        ScyllaCodec.encode_uuid(Attrs.get(attrs, :conversation_id)),
        ScyllaCodec.encode_date(Attrs.get(attrs, :bucket_date)),
        ScyllaCodec.encode_uuid(Attrs.get(attrs, :message_id))
      ]
    )
  end
end
