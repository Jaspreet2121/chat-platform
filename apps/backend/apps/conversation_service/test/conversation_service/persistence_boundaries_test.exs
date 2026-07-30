defmodule ConversationService.PersistenceBoundariesTest do
  use ExUnit.Case, async: true

  @conversation_id "11111111-1111-1111-1111-111111111111"
  @user_id "22222222-2222-2222-2222-222222222222"
  @now DateTime.utc_now()
       |> DateTime.truncate(:microsecond)

  test "ConversationStore builds create and update changesets" do
    changeset =
      ConversationService.ConversationStore.conversation_changeset(%{
        "type" => "group",
        "title" => "Launch Team",
        "created_by" => @user_id
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :status) == "active"

    update_changeset =
      %ConversationService.Schemas.Conversation{
        id: @conversation_id,
        type: "group",
        created_by: @user_id
      }
      |> ConversationService.ConversationStore.conversation_update_changeset(%{
        "title" => "Updated",
        "status" => "archived"
      })

    assert update_changeset.valid?
    assert Ecto.Changeset.get_field(update_changeset, :title) == "Updated"
  end

  test "ParticipantStore builds add and remove changesets" do
    changeset =
      ConversationService.ParticipantStore.participant_changeset(%{
        "conversation_id" => @conversation_id,
        "user_id" => @user_id
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :role) == "member"

    remove_changeset =
      %ConversationService.Schemas.ConversationParticipant{
        conversation_id: @conversation_id,
        user_id: @user_id,
        role: "member"
      }
      |> ConversationService.ParticipantStore.participant_remove_changeset(%{
        "left_at" => @now,
        # 078: every left row must say WHY ('removed' = moderation, 'left' = voluntary leave) — the
        # invite-link rejoin rule keys off it, so a reason-less left row would be unclassifiable.
        "left_reason" => "removed"
      })

    assert remove_changeset.valid?
    assert Ecto.Changeset.get_field(remove_changeset, :left_at) == @now
    assert Ecto.Changeset.get_field(remove_changeset, :left_reason) == "removed"

    # A reason-less removal is now INVALID by contract.
    reasonless =
      %ConversationService.Schemas.ConversationParticipant{
        conversation_id: @conversation_id,
        user_id: @user_id,
        role: "member"
      }
      |> ConversationService.ParticipantStore.participant_remove_changeset(%{"left_at" => @now})

    refute reasonless.valid?
  end

  test "ConversationSettingsStore builds create and update changesets" do
    changeset =
      ConversationService.ConversationSettingsStore.settings_changeset(%{
        "conversation_id" => @conversation_id,
        "only_admins_can_send" => true
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :only_admins_can_add_members) == false

    update_changeset =
      %ConversationService.Schemas.ConversationSettings{conversation_id: @conversation_id}
      |> ConversationService.ConversationSettingsStore.settings_update_changeset(%{
        "only_admins_can_send" => true,
        "only_admins_can_add_members" => true,
        "message_retention_days" => 90
      })

    assert update_changeset.valid?
    assert Ecto.Changeset.get_field(update_changeset, :message_retention_days) == 90
  end

  test "GroupProfileStore builds create and update changesets" do
    changeset =
      ConversationService.GroupProfileStore.group_profile_changeset(%{
        "conversation_id" => @conversation_id,
        "name" => "Launch Team"
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :name) == "Launch Team"

    update_changeset =
      %ConversationService.Schemas.GroupProfile{conversation_id: @conversation_id, name: "Launch"}
      |> ConversationService.GroupProfileStore.group_profile_update_changeset(%{
        "name" => "Launch Team",
        "description" => "Planning group"
      })

    assert update_changeset.valid?
    assert Ecto.Changeset.get_field(update_changeset, :description) == "Planning group"
  end
end
