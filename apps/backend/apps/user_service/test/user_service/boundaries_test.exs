defmodule UserService.BoundariesTest do
  use ExUnit.Case, async: true

  test "Profiles boundary returns current profile placeholder" do
    assert {:ok, profile} = UserService.Profiles.get_current_profile(%{})
    assert profile.user_id == "user_placeholder"
    assert profile.display_name == "Placeholder User"
    assert profile.settings.locale == "en"
    assert profile.privacy.read_receipts_enabled == true
  end

  test "Profiles boundary returns updated profile placeholder" do
    assert {:ok, profile} =
             UserService.Profiles.update_current_profile(%{
               "display_name" => "Jaspreet",
               "bio" => "Building chat-platform",
               "avatar_media_id" => "media_placeholder"
             })

    assert profile.user_id == "user_placeholder"
    assert profile.display_name == "Jaspreet"
    assert profile.bio == "Building chat-platform"
    assert profile.avatar_media_id == "media_placeholder"
  end

  test "Profiles boundary returns public profile placeholder" do
    assert {:ok, profile} = UserService.Profiles.get_public_profile(%{"user_id" => "user_123"})
    assert profile.user_id == "user_123"
    assert profile.display_name == "Placeholder User"
  end

  test "Settings boundary returns placeholder settings" do
    assert {:ok, settings} = UserService.Settings.get_settings(%{})
    assert settings.locale == "en"
    assert settings.timezone == "UTC"
  end

  test "Privacy boundary returns placeholder privacy settings" do
    assert {:ok, privacy} = UserService.Privacy.get_privacy(%{})
    assert privacy.last_seen_visibility == "contacts"
    assert privacy.profile_photo_visibility == "contacts"
    assert privacy.read_receipts_enabled == true
  end
end
