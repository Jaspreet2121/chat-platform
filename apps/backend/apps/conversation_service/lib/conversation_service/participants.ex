defmodule ConversationService.Participants do
  @moduledoc """
  Conversation participant boundary.
  """

  alias ConversationService.ConversationStore
  alias ConversationService.ParticipantEvents
  alias ConversationService.ParticipantStore

  @type participant_attrs :: map()
  @type result :: {:ok, map()} | {:error, atom()}

  @callback add_participant(participant_attrs()) :: result()
  @callback remove_participant(participant_attrs()) :: result()

  def add_participant(attrs) do
    if conversation_persistence_enabled?() do
      add_participant_in_db(attrs)
    else
      placeholder_add_participant(attrs)
    end
  end

  def remove_participant(attrs) do
    if conversation_persistence_enabled?() do
      remove_participant_in_db(attrs)
    else
      placeholder_remove_participant(attrs)
    end
  end

  def placeholder_participants do
    [
      %{
        user_id: "user_123",
        role: "member",
        joined_at: "2026-06-17T10:00:00Z"
      }
    ]
  end

  defp add_participant_in_db(attrs) do
    with {:ok, conversation_id} <- required_attr(attrs, "conversation_id"),
         {:ok, target_user_id} <- required_attr(attrs, "user_id"),
         {:ok, actor_user_id} <- required_attr(attrs, "actor_user_id"),
         {:ok, role} <- participant_role(attrs),
         {:ok, _conversation} <- fetch_active_conversation(conversation_id),
         {:ok, _actor_participant} <- require_owner(conversation_id, actor_user_id),
         :ok <- ensure_not_active_participant(conversation_id, target_user_id),
         {:ok, participant} <-
           ParticipantStore.add_participant(%{
             "conversation_id" => conversation_id,
             "user_id" => target_user_id,
             "role" => role,
             "joined_at" => now()
           }) do
      # After a successful persist, emit participant_added (fire-and-forget).
      ParticipantEvents.publish_participant_added(%{
        conversation_id: conversation_id,
        user_id: target_user_id,
        role: role,
        added_by: actor_user_id
      })

      {:ok, participant_response(participant)}
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    Ecto.Query.CastError -> {:error, :participant_invalid}
  end

  defp remove_participant_in_db(attrs) do
    with {:ok, conversation_id} <- required_attr(attrs, "conversation_id"),
         {:ok, target_user_id} <- required_attr(attrs, "user_id"),
         {:ok, actor_user_id} <- required_attr(attrs, "actor_user_id"),
         {:ok, _conversation} <- fetch_active_conversation(conversation_id),
         {:ok, _actor_participant} <- require_owner(conversation_id, actor_user_id),
         {:ok, target_participant} <- fetch_active_participant(conversation_id, target_user_id),
         :ok <- ensure_not_owner(target_participant),
         {:ok, removed_participant} <-
           ParticipantStore.remove_participant(target_participant, %{
             "left_at" => now()
           }) do
      # After a successful persist, emit participant_removed (fire-and-forget).
      ParticipantEvents.publish_participant_removed(%{
        conversation_id: conversation_id,
        user_id: target_user_id,
        removed_by: actor_user_id
      })

      {:ok,
       %{
         conversation_id: removed_participant.conversation_id,
         user_id: removed_participant.user_id,
         removed: true,
         left_at: iso8601(removed_participant.left_at)
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    Ecto.Query.CastError -> {:error, :participant_invalid}
  end

  defp fetch_active_conversation(conversation_id) do
    case ConversationStore.get_conversation(conversation_id) do
      nil -> {:error, :conversation_not_found}
      %{status: "active"} = conversation -> {:ok, conversation}
      _conversation -> {:error, :conversation_not_found}
    end
  end

  defp require_owner(conversation_id, actor_user_id) do
    with {:ok, participant} <- fetch_active_participant(conversation_id, actor_user_id) do
      if participant.role == "owner" do
        {:ok, participant}
      else
        {:error, :participant_forbidden}
      end
    end
  end

  defp fetch_active_participant(conversation_id, user_id) do
    case ParticipantStore.get_participant(conversation_id, user_id) do
      nil -> {:error, :participant_not_found}
      %{left_at: nil} = participant -> {:ok, participant}
      _participant -> {:error, :participant_not_found}
    end
  end

  defp ensure_not_active_participant(conversation_id, user_id) do
    case ParticipantStore.get_participant(conversation_id, user_id) do
      nil -> :ok
      %{left_at: nil} -> {:error, :participant_already_exists}
      _left_participant -> {:error, :participant_already_exists}
    end
  end

  defp ensure_not_owner(%{role: "owner"}), do: {:error, :participant_owner_remove_forbidden}
  defp ensure_not_owner(_participant), do: :ok

  defp participant_role(attrs) do
    role = get_attr(attrs, "role") || "member"

    if role in ["member", "admin"] do
      {:ok, role}
    else
      {:error, :participant_invalid}
    end
  end

  defp participant_response(participant) do
    %{
      conversation_id: participant.conversation_id,
      user_id: participant.user_id,
      role: participant.role,
      joined_at: iso8601(participant.joined_at)
    }
  end

  defp placeholder_add_participant(attrs) do
    {:ok,
     %{
       conversation_id: Map.get(attrs, "conversation_id", "conv_placeholder"),
       user_id: Map.get(attrs, "user_id", "user_placeholder"),
       role: Map.get(attrs, "role", "member"),
       joined_at: "2026-06-17T10:00:00Z"
     }}
  end

  defp placeholder_remove_participant(attrs) do
    {:ok,
     %{
       conversation_id: Map.get(attrs, "conversation_id", "conv_placeholder"),
       user_id: Map.get(attrs, "user_id", "user_placeholder"),
       removed: true
     }}
  end

  defp required_attr(attrs, key) do
    case get_attr(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :participant_invalid}
    end
  end

  defp get_attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp conversation_persistence_enabled? do
    Application.get_env(:conversation_service, :conversation_persistence, false) ||
      System.get_env("CONVERSATION_DB_BACKED") in ["true", "1", "yes"]
  end
end
