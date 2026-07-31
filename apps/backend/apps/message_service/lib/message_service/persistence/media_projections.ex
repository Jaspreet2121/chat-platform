defmodule MessageService.Persistence.MediaProjections do
  @moduledoc """
  Query plans for the C3 media projections (`messages_by_media`, `media_by_conversation`).

  AUTHORITY: `messages_by_conversation` — both tables are rebuildable derivations (invariant stated in
  002's header and the adapter moduledoc). The tombstone write here is the same-primary-key INSERT
  whose replace identity ScyllaSchemaShapeTest proves live.
  """

  alias MessageService.Persistence.Attrs
  alias MessageService.Persistence.QueryPlan
  alias MessageService.Persistence.ScyllaCodec

  def insert_reference_plan(attrs) do
    QueryPlan.new(
      :insert_media_reference,
      "messages_by_media",
      """
      INSERT INTO messages_by_media (media_id, created_at, message_id, conversation_id, sender_user_id)
      VALUES (?, ?, ?, ?, ?)
      """,
      [
        ScyllaCodec.encode_uuid(Attrs.get(attrs, :media_id)),
        ScyllaCodec.encode_timestamp(Attrs.get(attrs, :created_at)),
        ScyllaCodec.encode_uuid(Attrs.get(attrs, :message_id)),
        ScyllaCodec.encode_uuid(Attrs.get(attrs, :conversation_id)),
        ScyllaCodec.encode_uuid(Attrs.get(attrs, :sender_user_id))
      ]
    )
  end

  def list_references_plan(attrs) do
    QueryPlan.new(
      :list_media_references,
      "messages_by_media",
      """
      SELECT media_id, created_at, message_id, conversation_id, sender_user_id
      FROM messages_by_media WHERE media_id = ?
      """,
      [ScyllaCodec.encode_uuid(Attrs.get(attrs, :media_id))]
    )
  end

  def earliest_reference_plan(attrs) do
    QueryPlan.new(
      :earliest_media_reference,
      "messages_by_media",
      "SELECT conversation_id FROM messages_by_media WHERE media_id = ? LIMIT 1",
      [ScyllaCodec.encode_uuid(Attrs.get(attrs, :media_id))]
    )
  end

  @doc "Also the TOMBSTONE write: same primary key with deleted=true REPLACES the row."
  def upsert_gallery_plan(attrs) do
    QueryPlan.new(
      :upsert_media_gallery,
      "media_by_conversation",
      """
      INSERT INTO media_by_conversation
        (conversation_id, created_at, message_id, media_id, sender_user_id, deleted, metadata)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      """,
      [
        ScyllaCodec.encode_uuid(Attrs.get(attrs, :conversation_id)),
        ScyllaCodec.encode_timestamp(Attrs.get(attrs, :created_at)),
        ScyllaCodec.encode_uuid(Attrs.get(attrs, :message_id)),
        ScyllaCodec.encode_uuid(Attrs.get(attrs, :media_id)),
        ScyllaCodec.encode_uuid(Attrs.get(attrs, :sender_user_id)),
        Attrs.get(attrs, :deleted) == true,
        ScyllaCodec.encode_metadata(Attrs.get(attrs, :metadata))
      ]
    )
  end

  def list_gallery_plan(attrs) do
    case Attrs.get(attrs, :before) do
      nil ->
        QueryPlan.new(
          :list_media_gallery,
          "media_by_conversation",
          """
          SELECT conversation_id, created_at, message_id, media_id, sender_user_id, deleted, metadata
          FROM media_by_conversation WHERE conversation_id = ? LIMIT ?
          """,
          [
            ScyllaCodec.encode_uuid(Attrs.get(attrs, :conversation_id)),
            Attrs.get(attrs, :limit)
          ]
        )

      before ->
        QueryPlan.new(
          :list_media_gallery_before,
          "media_by_conversation",
          """
          SELECT conversation_id, created_at, message_id, media_id, sender_user_id, deleted, metadata
          FROM media_by_conversation WHERE conversation_id = ? AND created_at < ? LIMIT ?
          """,
          [
            ScyllaCodec.encode_uuid(Attrs.get(attrs, :conversation_id)),
            ScyllaCodec.encode_timestamp(before),
            Attrs.get(attrs, :limit)
          ]
        )
    end
  end
end
