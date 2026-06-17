defmodule MessageService.Persistence.MessageReactions do
  @moduledoc """
  Query plans for `message_reactions_by_message`.
  """

  alias MessageService.Persistence.Attrs
  alias MessageService.Persistence.QueryPlan

  @table "message_reactions_by_message"

  def upsert_reaction_plan(attrs) do
    QueryPlan.new(
      :upsert_message_reaction,
      @table,
      """
      INSERT INTO message_reactions_by_message (
        conversation_id, message_id, user_id, reaction, created_at
      ) VALUES (?, ?, ?, ?, ?)
      """,
      [
        Attrs.get(attrs, :conversation_id),
        Attrs.get(attrs, :message_id),
        Attrs.get(attrs, :user_id),
        Attrs.get(attrs, :reaction),
        Attrs.get(attrs, :created_at)
      ]
    )
  end

  def delete_reaction_plan(attrs) do
    QueryPlan.new(
      :delete_message_reaction,
      @table,
      """
      DELETE FROM message_reactions_by_message
      WHERE conversation_id = ? AND message_id = ? AND user_id = ?
      """,
      [
        Attrs.get(attrs, :conversation_id),
        Attrs.get(attrs, :message_id),
        Attrs.get(attrs, :user_id)
      ]
    )
  end

  def list_for_message_plan(attrs) do
    QueryPlan.new(
      :list_message_reactions,
      @table,
      """
      SELECT conversation_id, message_id, user_id, reaction, created_at
      FROM message_reactions_by_message
      WHERE conversation_id = ? AND message_id = ?
      """,
      [
        Attrs.get(attrs, :conversation_id),
        Attrs.get(attrs, :message_id)
      ]
    )
  end
end
