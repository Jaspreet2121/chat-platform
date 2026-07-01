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

  # Tenant-scoped fetch for the public /v1 isolation gate: an ACTIVE conversation that belongs to
  # `app_id`, else nil. The (app_id, id) predicate IS the isolation boundary — a cross-tenant or
  # unknown id both return nil (no separate existence signal). Backed by idx_conversations_app_id_id.
  # Ecto binds id/app_id as uuids via the schema field types, so no raw ::text::uuid cast is needed
  # here (that guard is only for the raw Postgrex outbox queries).
  def get_conversation_in_app(id, app_id) when is_binary(id) and is_binary(app_id) do
    Repo.one(
      from(conversation in Conversation,
        where:
          conversation.id == ^id and conversation.app_id == ^app_id and
            conversation.status == "active"
      )
    )
  end

  def get_conversation_in_app(_id, _app_id), do: nil

  # Existing direct conversation for a canonical pair key WITHIN an app (the unique index is
  # (app_id, direct_key) WHERE type='direct'). NULL keys / non-direct / other apps never match.
  def get_by_direct_key(app_id, direct_key) when is_binary(app_id) and is_binary(direct_key) do
    Repo.one(
      from(conversation in Conversation,
        where:
          conversation.type == "direct" and conversation.app_id == ^app_id and
            conversation.direct_key == ^direct_key
      )
    )
  end

  def get_by_direct_key(_app_id, _direct_key), do: nil

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
