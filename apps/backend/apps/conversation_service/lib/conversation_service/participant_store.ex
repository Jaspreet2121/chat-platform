defmodule ConversationService.ParticipantStore do
  @moduledoc """
  Data-access boundary for conversation participant persistence.
  """

  import Ecto.Query

  alias ConversationService.Repo
  alias ConversationService.Schemas.ConversationParticipant

  def participant_changeset(attrs \\ %{}) do
    ConversationParticipant.changeset(%ConversationParticipant{}, attrs)
  end

  def participant_remove_changeset(%ConversationParticipant{} = participant, attrs) do
    ConversationParticipant.remove_changeset(participant, attrs)
  end

  def add_participant(attrs) do
    attrs
    |> participant_changeset()
    |> Repo.insert()
  end

  def get_participant(conversation_id, user_id) do
    Repo.get_by(ConversationParticipant, conversation_id: conversation_id, user_id: user_id)
  end

  def list_active_participants(conversation_id) do
    ConversationParticipant
    |> where(
      [participant],
      participant.conversation_id == ^conversation_id and is_nil(participant.left_at)
    )
    |> order_by([participant], asc: participant.joined_at)
    |> Repo.all()
  end

  def remove_participant(%ConversationParticipant{} = participant, attrs) do
    participant
    |> participant_remove_changeset(attrs)
    |> Repo.update()
  end

  # Reactivate a LEFT row (rejoin): clears left_at/left_reason, resets role + joined_at.
  def reactivate_participant(%ConversationParticipant{} = participant, attrs) do
    participant
    |> ConversationParticipant.reactivate_changeset(attrs)
    |> Repo.update()
    |> tap(fn
      # A rejoin returns a row whose counter went unmaintained for the whole absence (086) — recount
      # from source truth. Here so BOTH reactivation callers (owner-add and invite join) get it.
      {:ok, reactivated} ->
        ConversationService.InboxCounters.recount(
          reactivated.conversation_id,
          reactivated.user_id
        )

      _ ->
        :ok
    end)
  end
end
