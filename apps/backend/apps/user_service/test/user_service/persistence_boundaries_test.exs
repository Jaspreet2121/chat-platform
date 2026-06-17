defmodule UserService.PersistenceBoundariesTest do
  use ExUnit.Case, async: true

  @user_id "11111111-1111-1111-1111-111111111111"

  test "ProfileStore builds create and update changesets" do
    changeset =
      UserService.ProfileStore.profile_changeset(%{
        "user_id" => @user_id,
        "display_name" => "Jaspreet",
        "bio" => "Building chat-platform"
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :display_name) == "Jaspreet"

    update_changeset =
      %UserService.Schemas.UserProfile{user_id: @user_id, display_name: "Placeholder User"}
      |> UserService.ProfileStore.profile_update_changeset(%{"display_name" => "Updated"})

    assert update_changeset.valid?
    assert Ecto.Changeset.get_field(update_changeset, :display_name) == "Updated"
  end

  test "SettingsStore builds create and update changesets" do
    changeset =
      UserService.SettingsStore.settings_changeset(%{
        "user_id" => @user_id,
        "settings" => %{"theme" => "system"}
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :locale) == "en"

    update_changeset =
      %UserService.Schemas.UserSettings{user_id: @user_id}
      |> UserService.SettingsStore.settings_update_changeset(%{
        "locale" => "en-IN",
        "timezone" => "Asia/Kolkata",
        "settings" => %{"theme" => "dark"}
      })

    assert update_changeset.valid?
    assert Ecto.Changeset.get_field(update_changeset, :timezone) == "Asia/Kolkata"
  end

  test "PrivacyStore builds create and update changesets" do
    changeset = UserService.PrivacyStore.privacy_changeset(%{"user_id" => @user_id})

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :read_receipts_enabled) == true

    update_changeset =
      %UserService.Schemas.UserPrivacySettings{user_id: @user_id}
      |> UserService.PrivacyStore.privacy_update_changeset(%{
        "last_seen_visibility" => "nobody",
        "profile_photo_visibility" => "contacts",
        "read_receipts_enabled" => false
      })

    assert update_changeset.valid?
    assert Ecto.Changeset.get_field(update_changeset, :last_seen_visibility) == "nobody"
  end
end
