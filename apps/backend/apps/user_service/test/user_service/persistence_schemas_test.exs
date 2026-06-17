defmodule UserService.PersistenceSchemasTest do
  use ExUnit.Case, async: true

  alias UserService.Schemas.UserPrivacySettings
  alias UserService.Schemas.UserProfile
  alias UserService.Schemas.UserSettings

  @user_id "11111111-1111-1111-1111-111111111111"
  @avatar_media_id "22222222-2222-2222-2222-222222222222"

  test "user_profiles changeset validates required profile fields" do
    assert UserProfile.changeset(%UserProfile{}, %{
             "user_id" => @user_id,
             "display_name" => "Jaspreet",
             "avatar_media_id" => @avatar_media_id,
             "bio" => "Building chat-platform"
           }).valid?

    invalid = UserProfile.changeset(%UserProfile{}, %{"user_id" => @user_id})

    refute invalid.valid?
    assert Keyword.has_key?(invalid.errors, :display_name)
  end

  test "user_profiles update changeset allows profile field updates" do
    profile = %UserProfile{user_id: @user_id, display_name: "Placeholder User"}

    changeset =
      UserProfile.update_changeset(profile, %{
        "display_name" => "Jaspreet",
        "bio" => "Updated bio"
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :display_name) == "Jaspreet"
  end

  test "user_settings changeset applies defaults and validates required user id" do
    changeset = UserSettings.changeset(%UserSettings{}, %{"user_id" => @user_id})

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :locale) == "en"
    assert Ecto.Changeset.get_field(changeset, :timezone) == "UTC"
    assert Ecto.Changeset.get_field(changeset, :settings) == %{}

    invalid = UserSettings.changeset(%UserSettings{}, %{})

    refute invalid.valid?
    assert Keyword.has_key?(invalid.errors, :user_id)
  end

  test "user_privacy_settings changeset applies defaults and validates visibility values" do
    changeset = UserPrivacySettings.changeset(%UserPrivacySettings{}, %{"user_id" => @user_id})

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :last_seen_visibility) == "contacts"
    assert Ecto.Changeset.get_field(changeset, :profile_photo_visibility) == "contacts"
    assert Ecto.Changeset.get_field(changeset, :read_receipts_enabled) == true

    invalid =
      UserPrivacySettings.changeset(%UserPrivacySettings{}, %{
        "user_id" => @user_id,
        "last_seen_visibility" => "friends",
        "profile_photo_visibility" => "public"
      })

    refute invalid.valid?
    assert Keyword.has_key?(invalid.errors, :last_seen_visibility)
    assert Keyword.has_key?(invalid.errors, :profile_photo_visibility)
  end
end
