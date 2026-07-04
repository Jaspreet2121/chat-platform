defmodule ConversationService.PostgresIntegrationTest do
  use ExUnit.Case, async: false

  alias ConversationService.Conversations
  alias ConversationService.Participants
  alias ConversationService.Repo
  alias ConversationService.Schemas.Conversation
  alias ConversationService.Schemas.ConversationParticipant

  @tag :postgres_integration
  test "create_conversation creates DB-backed conversation with owner and members" do
    creator_id = Ecto.UUID.generate()
    participant_id = Ecto.UUID.generate()

    insert_user_auth_parent!(creator_id)
    insert_user_auth_parent!(participant_id)

    assert {:ok, response} =
             Conversations.create_conversation(%{
               "type" => "group",
               "title" => "Launch Team",
               "created_by" => creator_id,
               "participant_user_ids" => [participant_id]
             })

    assert response.conversation_id
    assert response.type == "group"
    assert response.title == "Launch Team"
    assert response.created_by == creator_id
    assert Enum.sort(response.participant_user_ids) == Enum.sort([creator_id, participant_id])
    assert is_binary(response.created_at)

    assert %Conversation{} = Repo.get(Conversation, response.conversation_id)

    assert %ConversationParticipant{role: "owner"} =
             Repo.get_by(ConversationParticipant,
               conversation_id: response.conversation_id,
               user_id: creator_id
             )

    assert %ConversationParticipant{role: "member"} =
             Repo.get_by(ConversationParticipant,
               conversation_id: response.conversation_id,
               user_id: participant_id
             )
  end

  @tag :postgres_integration
  test "group profile: created on group creation, owner-gated update + set/clear photo" do
    owner_id = Ecto.UUID.generate()
    member_id = Ecto.UUID.generate()
    insert_user_auth_parent!(owner_id)
    insert_user_auth_parent!(member_id)

    {:ok, conv} =
      Conversations.create_conversation(%{
        "type" => "group",
        "title" => "Launch Team",
        "created_by" => owner_id,
        "participant_user_ids" => [member_id]
      })

    cid = conv.conversation_id

    # A group_profiles row is created on group creation (name from the title).
    assert %ConversationService.Schemas.GroupProfile{name: "Launch Team"} =
             ConversationService.GroupProfileStore.get_group_profile(cid)

    # NON-owner cannot change the group profile.
    assert {:error, :conversation_forbidden} =
             Conversations.set_group_profile(%{
               "conversation_id" => cid,
               "actor_user_id" => member_id,
               "name" => "Hijacked"
             })

    # Owner sets a photo.
    media_id = Ecto.UUID.generate()

    assert {:ok, set} =
             Conversations.set_group_profile(%{
               "conversation_id" => cid,
               "actor_user_id" => owner_id,
               "avatar_media_id" => media_id,
               "avatar_object_key" => "media/group/photo.png"
             })

    assert set.avatar_media_id == media_id
    assert set.avatar_object_key == "media/group/photo.png"

    # Empty-string avatar fields REMOVE the photo (revert to initials).
    assert {:ok, cleared} =
             Conversations.set_group_profile(%{
               "conversation_id" => cid,
               "actor_user_id" => owner_id,
               "avatar_media_id" => "",
               "avatar_object_key" => ""
             })

    assert cleared.avatar_media_id == nil
    assert cleared.avatar_object_key == nil
  end

  @tag :postgres_integration
  test "create_conversation rejects missing participants" do
    creator_id = Ecto.UUID.generate()
    insert_user_auth_parent!(creator_id)

    assert {:error, :conversation_invalid} =
             Conversations.create_conversation(%{
               "type" => "group",
               "title" => "Launch Team",
               "created_by" => creator_id,
               "participant_user_ids" => []
             })
  end

  @tag :postgres_integration
  test "list_conversations returns DB-backed conversations for a participant" do
    creator_id = Ecto.UUID.generate()
    participant_id = Ecto.UUID.generate()
    outsider_id = Ecto.UUID.generate()

    insert_user_auth_parent!(creator_id)
    insert_user_auth_parent!(participant_id)
    insert_user_auth_parent!(outsider_id)

    assert {:ok, matching_response} =
             Conversations.create_conversation(%{
               "type" => "group",
               "title" => "Launch Team",
               "created_by" => creator_id,
               "participant_user_ids" => [participant_id]
             })

    assert {:ok, outsider_response} =
             Conversations.create_conversation(%{
               "type" => "group",
               "title" => "Private Outsider Team",
               "created_by" => outsider_id,
               "participant_user_ids" => [outsider_id]
             })

    assert {:ok, list_response} =
             Conversations.list_conversations(%{
               "user_id" => participant_id
             })

    conversation_ids = Enum.map(list_response.conversations, & &1.conversation_id)

    assert matching_response.conversation_id in conversation_ids
    refute outsider_response.conversation_id in conversation_ids

    listed_conversation =
      Enum.find(
        list_response.conversations,
        &(&1.conversation_id == matching_response.conversation_id)
      )

    assert listed_conversation.type == "group"
    assert listed_conversation.title == "Launch Team"
    assert listed_conversation.last_message_preview == nil
    assert listed_conversation.unread_count == 0
    assert is_binary(listed_conversation.updated_at)
  end

  @tag :postgres_integration
  test "get_conversation returns DB-backed conversation details for a participant" do
    creator_id = Ecto.UUID.generate()
    participant_id = Ecto.UUID.generate()
    outsider_id = Ecto.UUID.generate()

    insert_user_auth_parent!(creator_id)
    insert_user_auth_parent!(participant_id)
    insert_user_auth_parent!(outsider_id)

    assert {:ok, created_response} =
             Conversations.create_conversation(%{
               "type" => "group",
               "title" => "Launch Team",
               "created_by" => creator_id,
               "participant_user_ids" => [participant_id]
             })

    assert {:ok, show_response} =
             Conversations.get_conversation(%{
               "conversation_id" => created_response.conversation_id,
               "user_id" => participant_id
             })

    assert show_response.conversation_id == created_response.conversation_id
    assert show_response.type == "group"
    assert show_response.title == "Launch Team"
    assert show_response.created_by == creator_id

    participant_user_ids = Enum.map(show_response.participants, & &1.user_id)

    assert creator_id in participant_user_ids
    assert participant_id in participant_user_ids
    refute outsider_id in participant_user_ids

    owner = Enum.find(show_response.participants, &(&1.user_id == creator_id))
    member = Enum.find(show_response.participants, &(&1.user_id == participant_id))

    assert owner.role == "owner"
    assert member.role == "member"
    assert is_binary(owner.joined_at)
    assert is_binary(member.joined_at)

    assert {:error, :conversation_forbidden} =
             Conversations.get_conversation(%{
               "conversation_id" => created_response.conversation_id,
               "user_id" => outsider_id
             })

    assert {:error, :conversation_not_found} =
             Conversations.get_conversation(%{
               "conversation_id" => Ecto.UUID.generate(),
               "user_id" => creator_id
             })
  end

  @tag :postgres_integration
  test "owner can add DB-backed participant" do
    owner_id = Ecto.UUID.generate()
    member_id = Ecto.UUID.generate()
    new_participant_id = Ecto.UUID.generate()

    insert_user_auth_parent!(owner_id)
    insert_user_auth_parent!(member_id)
    insert_user_auth_parent!(new_participant_id)

    assert {:ok, created_response} =
             Conversations.create_conversation(%{
               "type" => "group",
               "title" => "Launch Team",
               "created_by" => owner_id,
               "participant_user_ids" => [member_id]
             })

    assert {:ok, add_response} =
             Participants.add_participant(%{
               "conversation_id" => created_response.conversation_id,
               "actor_user_id" => owner_id,
               "user_id" => new_participant_id,
               "role" => "member"
             })

    assert add_response.conversation_id == created_response.conversation_id
    assert add_response.user_id == new_participant_id
    assert add_response.role == "member"
    assert is_binary(add_response.joined_at)

    assert %ConversationParticipant{role: "member", left_at: nil} =
             Repo.get_by(ConversationParticipant,
               conversation_id: created_response.conversation_id,
               user_id: new_participant_id
             )
  end

  @tag :postgres_integration
  test "non-owner cannot add DB-backed participant" do
    owner_id = Ecto.UUID.generate()
    member_id = Ecto.UUID.generate()
    new_participant_id = Ecto.UUID.generate()

    insert_user_auth_parent!(owner_id)
    insert_user_auth_parent!(member_id)
    insert_user_auth_parent!(new_participant_id)

    assert {:ok, created_response} =
             Conversations.create_conversation(%{
               "type" => "group",
               "title" => "Launch Team",
               "created_by" => owner_id,
               "participant_user_ids" => [member_id]
             })

    assert {:error, :participant_forbidden} =
             Participants.add_participant(%{
               "conversation_id" => created_response.conversation_id,
               "actor_user_id" => member_id,
               "user_id" => new_participant_id,
               "role" => "member"
             })
  end

  @tag :postgres_integration
  test "owner can remove DB-backed member and removed member is hidden" do
    owner_id = Ecto.UUID.generate()
    member_id = Ecto.UUID.generate()

    insert_user_auth_parent!(owner_id)
    insert_user_auth_parent!(member_id)

    assert {:ok, created_response} =
             Conversations.create_conversation(%{
               "type" => "group",
               "title" => "Launch Team",
               "created_by" => owner_id,
               "participant_user_ids" => [member_id]
             })

    assert {:ok, remove_response} =
             Participants.remove_participant(%{
               "conversation_id" => created_response.conversation_id,
               "actor_user_id" => owner_id,
               "user_id" => member_id
             })

    assert remove_response.conversation_id == created_response.conversation_id
    assert remove_response.user_id == member_id
    assert remove_response.removed == true
    assert is_binary(remove_response.left_at)

    removed_participant =
      Repo.get_by!(ConversationParticipant,
        conversation_id: created_response.conversation_id,
        user_id: member_id
      )

    assert removed_participant.left_at != nil

    assert {:ok, owner_show_response} =
             Conversations.get_conversation(%{
               "conversation_id" => created_response.conversation_id,
               "user_id" => owner_id
             })

    participant_user_ids = Enum.map(owner_show_response.participants, & &1.user_id)
    refute member_id in participant_user_ids

    assert {:error, :conversation_forbidden} =
             Conversations.get_conversation(%{
               "conversation_id" => created_response.conversation_id,
               "user_id" => member_id
             })

    assert {:ok, list_response} =
             Conversations.list_conversations(%{
               "user_id" => member_id
             })

    assert list_response.conversations == []
  end

  @tag :postgres_integration
  test "owner cannot remove DB-backed owner participant" do
    owner_id = Ecto.UUID.generate()
    member_id = Ecto.UUID.generate()

    insert_user_auth_parent!(owner_id)
    insert_user_auth_parent!(member_id)

    assert {:ok, created_response} =
             Conversations.create_conversation(%{
               "type" => "group",
               "title" => "Launch Team",
               "created_by" => owner_id,
               "participant_user_ids" => [member_id]
             })

    assert {:error, :participant_owner_remove_forbidden} =
             Participants.remove_participant(%{
               "conversation_id" => created_response.conversation_id,
               "actor_user_id" => owner_id,
               "user_id" => owner_id
             })
  end

  setup do
    previous_persistence =
      Application.get_env(:conversation_service, :conversation_persistence, false)

    Application.put_env(:conversation_service, :conversation_persistence, true)

    start_repo!(Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    on_exit(fn ->
      Application.put_env(:conversation_service, :conversation_persistence, previous_persistence)
    end)

    :ok
  end

  defp insert_user_auth_parent!(user_id) do
    Repo.query!(
      """
      INSERT INTO users_auth (id, email, status)
      VALUES ($1, $2, 'active')
      """,
      [
        Ecto.UUID.dump!(user_id),
        "conversation-#{System.unique_integer([:positive])}@example.test"
      ]
    )
  end

  defp start_repo!(repo) do
    case repo.start_link() do
      {:ok, pid} ->
        Process.unlink(pid)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end
end
