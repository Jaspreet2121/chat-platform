defmodule ConversationService.Conversations do
  @moduledoc """
  Conversation metadata boundary.
  """

  alias ConversationService.ConversationStore
  alias ConversationService.ParticipantEvents
  alias ConversationService.ParticipantStore
  alias ConversationService.Repo

  @type conversation_attrs :: map()
  @type result :: {:ok, map()} | {:error, atom()}

  @callback create_conversation(conversation_attrs()) :: result()
  @callback list_conversations(conversation_attrs()) :: result()
  @callback get_conversation(conversation_attrs()) :: result()

  def create_conversation(attrs) do
    if conversation_persistence_enabled?() do
      create_conversation_in_db(attrs)
    else
      placeholder_create_conversation(attrs)
    end
  end

  def list_conversations(attrs) do
    if conversation_persistence_enabled?() do
      list_conversations_from_db(attrs)
    else
      placeholder_list_conversations()
    end
  end

  def get_conversation(attrs) do
    if conversation_persistence_enabled?() do
      get_conversation_from_db(attrs)
    else
      placeholder_get_conversation(attrs)
    end
  end

  defp get_conversation_from_db(attrs) do
    with {:ok, conversation_id} <- required_attr(attrs, "conversation_id"),
         {:ok, user_id} <- required_attr(attrs, "user_id"),
         {:ok, conversation} <- fetch_active_conversation(conversation_id),
         {:ok, _participant} <- fetch_active_participant(conversation_id, user_id) do
      participants =
        conversation_id
        |> ParticipantStore.list_active_participants()
        |> Enum.map(&participant_response/1)

      {:ok, conversation_detail_response(conversation, participants)}
    end
  rescue
    Ecto.Query.CastError -> {:error, :conversation_invalid}
  end

  defp fetch_active_conversation(conversation_id) do
    case ConversationStore.get_conversation(conversation_id) do
      nil -> {:error, :conversation_not_found}
      %{status: "active"} = conversation -> {:ok, conversation}
      _conversation -> {:error, :conversation_not_found}
    end
  end

  defp fetch_active_participant(conversation_id, user_id) do
    case ParticipantStore.get_participant(conversation_id, user_id) do
      nil -> {:error, :conversation_forbidden}
      %{left_at: nil} = participant -> {:ok, participant}
      _participant -> {:error, :conversation_forbidden}
    end
  end

  defp conversation_detail_response(conversation, participants) do
    %{
      conversation_id: conversation.id,
      tenant_id: conversation.tenant_id,
      type: conversation.type,
      title: conversation.title,
      created_by: conversation.created_by,
      participants: participants
    }
  end

  defp participant_response(participant) do
    %{
      user_id: participant.user_id,
      role: participant.role,
      joined_at: iso8601(participant.joined_at),
      left_at: iso8601(participant.left_at)
    }
  end

  defp placeholder_get_conversation(attrs) do
    {:ok,
     %{
       conversation_id: Map.get(attrs, "conversation_id", "conv_placeholder"),
       tenant_id: nil,
       type: "group",
       title: "Launch Team",
       participants: ConversationService.Participants.placeholder_participants()
     }}
  end

  defp list_conversations_from_db(attrs) do
    with {:ok, user_id} <- required_attr(attrs, "user_id") do
      conversations =
        user_id
        |> ConversationStore.list_conversations_for_user()
        |> Enum.map(&conversation_list_item/1)

      {:ok, %{conversations: conversations}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :conversation_invalid}
  end

  defp conversation_list_item(conversation) do
    %{
      conversation_id: conversation.id,
      type: conversation.type,
      title: conversation.title,
      last_message_preview: nil,
      unread_count: 0,
      updated_at: iso8601(conversation.updated_at)
    }
  end

  defp placeholder_list_conversations do
    {:ok,
     %{
       conversations: [
         %{
           conversation_id: "conv_placeholder",
           type: "group",
           title: "Launch Team",
           last_message_preview: nil,
           unread_count: 0,
           updated_at: "2026-06-17T10:00:00Z"
         }
       ]
     }}
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp create_conversation_in_db(attrs) do
    with {:ok, type} <- required_attr(attrs, "type"),
         {:ok, created_by} <- required_attr(attrs, "created_by"),
         {:ok, participant_user_ids} <- required_participant_user_ids(attrs) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      conversation_id = get_attr(attrs, "conversation_id") || Ecto.UUID.generate()

      participant_user_ids =
        participant_user_ids
        |> Enum.concat([created_by])
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      Repo.transaction(fn ->
        with {:ok, conversation} <-
               ConversationStore.create_conversation(%{
                 "id" => conversation_id,
                 "tenant_id" => get_attr(attrs, "tenant_id"),
                 "type" => type,
                 "title" => get_attr(attrs, "title"),
                 "avatar_media_id" => get_attr(attrs, "avatar_media_id"),
                 "created_by" => created_by,
                 "status" => "active",
                 "created_at" => now,
                 "updated_at" => now
               }),
             :ok <-
               add_initial_participants(conversation.id, created_by, participant_user_ids, now) do
          conversation_response(conversation, participant_user_ids)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, response} ->
          # After the tx COMMITS, emit one participant_added per initial participant
          # (fire-and-forget; never affects the create result).
          ParticipantEvents.publish_initial_participants(
            response.conversation_id,
            response.created_by,
            response.participant_user_ids
          )

          {:ok, response}

        {:error, _reason} ->
          {:error, :conversation_invalid}
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :conversation_invalid}
  end

  defp add_initial_participants(conversation_id, created_by, participant_user_ids, now) do
    participant_user_ids
    |> Enum.reduce_while(:ok, fn user_id, :ok ->
      role =
        if user_id == created_by do
          "owner"
        else
          "member"
        end

      case ParticipantStore.add_participant(%{
             "conversation_id" => conversation_id,
             "user_id" => user_id,
             "role" => role,
             "joined_at" => now
           }) do
        {:ok, _participant} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp conversation_response(conversation, participant_user_ids) do
    %{
      conversation_id: conversation.id,
      tenant_id: conversation.tenant_id,
      type: conversation.type,
      title: conversation.title,
      created_by: conversation.created_by,
      participant_user_ids: participant_user_ids,
      created_at: DateTime.to_iso8601(conversation.created_at)
    }
  end

  defp placeholder_create_conversation(attrs) do
    {:ok,
     %{
       conversation_id: "conv_placeholder",
       tenant_id: Map.get(attrs, "tenant_id"),
       type: Map.get(attrs, "type", "group"),
       title: Map.get(attrs, "title", "Launch Team"),
       created_by: "user_placeholder",
       participant_user_ids: Map.get(attrs, "participant_user_ids", []),
       created_at: "2026-06-17T10:00:00Z"
     }}
  end

  defp required_participant_user_ids(attrs) do
    case get_attr(attrs, "participant_user_ids") do
      user_ids when is_list(user_ids) and user_ids != [] -> {:ok, user_ids}
      _ -> {:error, :conversation_invalid}
    end
  end

  defp required_attr(attrs, key) do
    case get_attr(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :conversation_invalid}
    end
  end

  defp get_attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))
  end

  defp conversation_persistence_enabled? do
    Application.get_env(:conversation_service, :conversation_persistence, false) ||
      System.get_env("CONVERSATION_DB_BACKED") in ["true", "1", "yes"]
  end
end
