defmodule UserService.PostgresIntegrationTest do
  use UserService.DataCase, async: false

  # The public profile read is TENANT-SCOPED (get_public_profile_from_db requires app_id), so a
  # call without it returns :profile_invalid before touching the database. user_profiles.app_id
  # defaults to tenant zero, which is what these fixtures get.
  @tenant_zero "00000000-0000-0000-0000-000000000001"

  alias UserService.Schemas.UserProfile
  alias UserService.Profiles

  @tag :postgres_integration
  test "inserts and selects a user_profiles row through the user repo" do
    user_id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    insert_auth_user!(user_id)

    {1, _rows} =
      Repo.insert_all(UserProfile, [
        %{
          user_id: user_id,
          display_name: "Postgres Test User",
          bio: "Sandbox-backed profile",
          created_at: now,
          updated_at: now
        }
      ])

    assert %UserProfile{user_id: ^user_id, display_name: "Postgres Test User"} =
             Repo.get(UserProfile, user_id)
  end

  @tag :postgres_integration
  test "update_current_profile creates and updates a DB-backed user profile" do
    previous_persistence = Application.get_env(:user_service, :user_profile_persistence, false)
    Application.put_env(:user_service, :user_profile_persistence, true)

    on_exit(fn ->
      Application.put_env(:user_service, :user_profile_persistence, previous_persistence)
    end)

    user_id = Ecto.UUID.generate()

    insert_user_auth_parent!(user_id)

    assert {:ok, created_profile} =
             Profiles.update_current_profile(%{
               "user_id" => user_id,
               "display_name" => "Jaspreet",
               "bio" => "Building chat-platform"
             })

    assert created_profile.user_id == user_id
    assert created_profile.display_name == "Jaspreet"
    assert created_profile.bio == "Building chat-platform"
    assert created_profile.avatar_media_id == nil
    assert is_binary(created_profile.updated_at)

    assert {:ok, updated_profile} =
             Profiles.update_current_profile(%{
               "user_id" => user_id,
               "display_name" => "Jaspreet Singh",
               "bio" => "Updating DB-backed profile"
             })

    assert updated_profile.user_id == user_id
    assert updated_profile.display_name == "Jaspreet Singh"
    assert updated_profile.bio == "Updating DB-backed profile"
    assert is_binary(updated_profile.updated_at)
  end

  @tag :postgres_integration
  test "empty-string avatar fields CLEAR the photo (remove-photo path); nil leaves it unchanged" do
    previous_persistence = Application.get_env(:user_service, :user_profile_persistence, false)
    Application.put_env(:user_service, :user_profile_persistence, true)

    on_exit(fn ->
      Application.put_env(:user_service, :user_profile_persistence, previous_persistence)
    end)

    user_id = Ecto.UUID.generate()
    insert_user_auth_parent!(user_id)

    # Set an avatar.
    {:ok, _} =
      Profiles.update_current_profile(%{
        "user_id" => user_id,
        "display_name" => "Ana",
        "avatar_media_id" => Ecto.UUID.generate(),
        "avatar_object_key" => "media/ana/photo.png"
      })

    {:ok, set} = Profiles.get_public_profile(%{"user_id" => user_id, "app_id" => @tenant_zero})
    assert is_binary(set.avatar_media_id)
    assert is_binary(set.avatar_object_key)

    # A display-name-only update (nil avatars) must NOT wipe the photo.
    {:ok, _} = Profiles.update_current_profile(%{"user_id" => user_id, "display_name" => "Ana B"})
    {:ok, kept} = Profiles.get_public_profile(%{"user_id" => user_id, "app_id" => @tenant_zero})
    assert is_binary(kept.avatar_media_id)

    # Empty-string avatars = explicit REMOVE → columns cleared, name preserved.
    {:ok, _} =
      Profiles.update_current_profile(%{
        "user_id" => user_id,
        "avatar_media_id" => "",
        "avatar_object_key" => ""
      })

    {:ok, cleared} =
      Profiles.get_public_profile(%{"user_id" => user_id, "app_id" => @tenant_zero})

    assert cleared.avatar_media_id == nil
    assert cleared.avatar_object_key == nil
    assert cleared.display_name == "Ana B"
  end

  @tag :postgres_integration
  test "get_public_profile returns DB-backed public profile fields" do
    previous_persistence = Application.get_env(:user_service, :user_profile_persistence, false)
    Application.put_env(:user_service, :user_profile_persistence, true)

    on_exit(fn ->
      Application.put_env(:user_service, :user_profile_persistence, previous_persistence)
    end)

    user_id = Ecto.UUID.generate()
    avatar_media_id = Ecto.UUID.generate()

    insert_user_auth_parent!(user_id)

    assert {:ok, _created_profile} =
             Profiles.update_current_profile(%{
               "user_id" => user_id,
               "display_name" => "Public Jaspreet",
               "avatar_media_id" => avatar_media_id,
               "bio" => "Public profile bio"
             })

    assert {:ok, public_profile} =
             Profiles.get_public_profile(%{
               "user_id" => user_id,
               "app_id" => @tenant_zero
             })

    assert public_profile.user_id == user_id
    assert public_profile.display_name == "Public Jaspreet"
    assert public_profile.avatar_media_id == avatar_media_id
    assert public_profile.bio == "Public profile bio"
  end

  defp insert_auth_user!(user_id) do
    Repo.query!(
      """
      INSERT INTO users_auth (id, email, status)
      VALUES ($1, $2, 'active')
      """,
      [Ecto.UUID.dump!(user_id), "user-#{System.unique_integer([:positive])}@example.test"]
    )
  end

  defp insert_user_auth_parent!(user_id) do
    UserService.Repo.query!(
      """
      INSERT INTO users_auth (id, email, status)
      VALUES ($1, $2, 'active')
      """,
      [
        Ecto.UUID.dump!(user_id),
        "profile-update-#{System.unique_integer([:positive])}@example.test"
      ]
    )
  end
end
