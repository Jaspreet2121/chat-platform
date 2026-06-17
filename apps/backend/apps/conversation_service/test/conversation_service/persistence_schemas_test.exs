defmodule ConversationService.PersistenceSchemasTest do
  use ExUnit.Case, async: true

  alias ConversationService.Schemas.Conversation
  alias ConversationService.Schemas.ConversationParticipant
  alias ConversationService.Schemas.ConversationSettings
  alias ConversationService.Schemas.GroupProfile

  @conversation_id "11111111-1111-1111-1111-111111111111"
  @user_id "22222222-2222-2222-2222-222222222222"
  @tenant_id "33333333-3333-3333-3333-333333333333"
  @avatar_media_id "44444444-4444-4444-4444-444444444444"
  @now DateTime.utc_now()
       |> DateTime.truncate(:microsecond)

  test "conversations changeset validates type and status" do
    assert Conversation.changeset(%Conversation{}, %{
             "tenant_id" => @tenant_id,
             "type" => "group",
             "title" => "Launch Team",
             "avatar_media_id" => @avatar_media_id,
             "created_by" => @user_id
           }).valid?

    invalid =
      Conversation.changeset(%Conversation{}, %{
        "type" => "channel",
        "created_by" => @user_id,
        "status" => "pending"
      })

    refute invalid.valid?
    assert Keyword.has_key?(invalid.errors, :type)
    assert Keyword.has_key?(invalid.errors, :status)
  end

  test "conversation update changeset accepts mutable metadata" do
    conversation = %Conversation{id: @conversation_id, type: "group", created_by: @user_id}

    changeset =
      Conversation.update_changeset(conversation, %{
        "title" => "Updated Launch Team",
        "status" => "archived"
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :status) == "archived"
  end

  test "conversation_participants changeset validates role" do
    assert ConversationParticipant.changeset(%ConversationParticipant{}, %{
             "conversation_id" => @conversation_id,
             "user_id" => @user_id,
             "role" => "member",
             "joined_at" => @now
           }).valid?

    invalid =
      ConversationParticipant.changeset(%ConversationParticipant{}, %{
        "conversation_id" => @conversation_id,
        "user_id" => @user_id,
        "role" => "moderator"
      })

    refute invalid.valid?
    assert Keyword.has_key?(invalid.errors, :role)
  end

  test "conversation_settings changeset validates retention policy" do
    assert ConversationSettings.changeset(%ConversationSettings{}, %{
             "conversation_id" => @conversation_id,
             "message_retention_days" => 30
           }).valid?

    invalid =
      ConversationSettings.changeset(%ConversationSettings{}, %{
        "conversation_id" => @conversation_id,
        "message_retention_days" => 0
      })

    refute invalid.valid?
    assert Keyword.has_key?(invalid.errors, :message_retention_days)
  end

  test "group_profiles changeset validates required name" do
    assert GroupProfile.changeset(%GroupProfile{}, %{
             "conversation_id" => @conversation_id,
             "name" => "Launch Team",
             "description" => "Planning group",
             "avatar_media_id" => @avatar_media_id
           }).valid?

    invalid = GroupProfile.changeset(%GroupProfile{}, %{"conversation_id" => @conversation_id})

    refute invalid.valid?
    assert Keyword.has_key?(invalid.errors, :name)
  end
end
