defmodule ConversationService.ConversationStore do
  @moduledoc """
  Data-access boundary for conversation metadata persistence.
  """

  import Ecto.Query

  alias ConversationService.Repo
  alias ConversationService.Schemas.Conversation
  alias ConversationService.Schemas.ConversationParticipant

  def conversation_changeset(attrs \\ %{}) do
    Conversation.changeset(%Conversation{}, attrs)
  end

  def conversation_update_changeset(%Conversation{} = conversation, attrs) do
    Conversation.update_changeset(conversation, attrs)
  end

  def create_conversation(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs =
      attrs
      |> Map.put_new("id", Ecto.UUID.generate())
      |> Map.put_new("status", "active")
      |> Map.put_new("created_at", now)
      |> Map.put_new("updated_at", now)

    attrs
    |> conversation_changeset()
    |> Repo.insert()
  end

  def get_conversation(id), do: Repo.get(Conversation, id)

  def list_conversations do
    Conversation
    |> order_by([conversation], desc: conversation.updated_at)
    |> Repo.all()
  end

  def list_conversations_for_user(user_id) do
    Conversation
    |> join(:inner, [conversation], participant in ConversationParticipant,
      on: participant.conversation_id == conversation.id
    )
    |> where(
      [conversation, participant],
      participant.user_id == ^user_id and
        is_nil(participant.left_at) and
        conversation.status == "active"
    )
    |> order_by([conversation, _participant], desc: conversation.updated_at)
    |> Repo.all()
  end

  def update_conversation(%Conversation{} = conversation, attrs) do
    conversation
    |> conversation_update_changeset(attrs)
    |> Repo.update()
  end
end
