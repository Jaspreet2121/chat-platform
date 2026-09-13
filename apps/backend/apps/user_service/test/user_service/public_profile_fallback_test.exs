defmodule UserService.PublicProfileFallbackTest do
  @moduledoc """
  A REAL user never 404s on their own card (122), on real SQL.

  The public read used to be `Repo.get_by(UserProfile, user_id:, app_id:)` → nil → 404, and a row
  existed only after the first PATCH /users/me. Now an ACTIVE account in the caller's app with no
  row answers a minimal card (has_profile: false); everything that 404'd for a real reason —
  unknown id, another app, a non-active account — still does, with the same error.

  Also pinned: a profile row created at registration carries no name, so an avatar-only or
  bio-only update must be accepted for it, while blanking an existing name is still refused.
  """
  use UserService.DataCase, async: false

  alias UserService.{ProfileStore, Profiles}

  @tenant "00000000-0000-0000-0000-000000000001"
  @other_app "44444444-4444-4444-8444-444444444444"

  defp user!(status \\ "active", app_id \\ @tenant) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, status) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, $4)",
      [id, app_id, "+1555#{System.unique_integer([:positive])}", status]
    )

    id
  end

  defp card(user_id, app_id \\ @tenant),
    do: Profiles.get_public_profile(%{"user_id" => user_id, "app_id" => app_id})

  setup do
    prev = Application.get_env(:user_service, :user_profile_persistence, false)
    Application.put_env(:user_service, :user_profile_persistence, true)

    Repo.query!(
      "INSERT INTO apps (id, name, slug) VALUES ($1::text::uuid, 'Other', 'other') ON CONFLICT DO NOTHING",
      [@other_app]
    )

    on_exit(fn -> Application.put_env(:user_service, :user_profile_persistence, prev) end)
    :ok
  end

  # --- the defensive read --------------------------------------------------------------------------

  @tag :postgres_integration
  test "an ACTIVE account with no profile row answers a minimal card, not a 404" do
    id = user!()

    assert {:ok, profile} = card(id),
           "a real, active user with no row 404s — to every peer this account looks deleted"

    assert profile.user_id == id
    assert profile.has_profile == false
    assert profile.display_name == nil
    assert profile.avatar_media_id == nil

    # THE KEY-SET of the minimal card — the client reads has_profile to tell "unset" from "hidden".
    assert profile |> Map.keys() |> Enum.sort() == [
             :app_id,
             :avatar_media_id,
             :avatar_object_key,
             :bio,
             :display_name,
             :has_profile,
             :profile_visibility,
             :user_id,
             :username
           ]
  end

  @tag :postgres_integration
  test "the SAME account asked for through another app is still not found" do
    id = user!()

    assert {:error, :profile_not_found} = card(id, @other_app),
           "a cross-app id was answered — the fallback leaks accounts across tenants"
  end

  @tag :postgres_integration
  test "a NON-ACTIVE account with no row is still not found" do
    for status <- ["suspended", "deleted"] do
      id = user!(status)

      assert {:error, :profile_not_found} = card(id),
             "a #{status} account with no row was answered — only an ACTIVE account earns a card"
    end
  end

  @tag :postgres_integration
  test "an UNKNOWN id is still not found" do
    assert {:error, :profile_not_found} = card(Ecto.UUID.generate())
  end

  @tag :postgres_integration
  test "an account WITH a row is unchanged, and says has_profile: true" do
    id = user!()

    Repo.query!(
      "INSERT INTO user_profiles (user_id, app_id, display_name, bio) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'Asha', 'hi')",
      [id, @tenant]
    )

    assert {:ok, profile} = card(id)
    assert profile.has_profile == true
    assert profile.display_name == "Asha"
    assert profile.bio == "hi"
  end

  # --- a name-less row still takes updates -----------------------------------------------------------

  @tag :postgres_integration
  test "a registration row (no name) accepts a bio-only update; blanking a set name is refused" do
    id = user!()

    Repo.query!(
      "INSERT INTO user_profiles (user_id, app_id, display_name) VALUES ($1::text::uuid, $2::text::uuid, NULL)",
      [id, @tenant]
    )

    profile = ProfileStore.get_profile(id)
    assert profile.display_name == nil

    assert {:ok, updated} = ProfileStore.update_profile(profile, %{"bio" => "new here"}),
           "an avatar/bio-only update was refused for a row with no name yet — the user cannot " <>
             "change anything until they also pick a name"

    assert updated.bio == "new here"

    {:ok, named} = ProfileStore.update_profile(updated, %{"display_name" => "Asha"})
    assert named.display_name == "Asha"

    assert {:error, changeset} = ProfileStore.update_profile(named, %{"display_name" => ""})
    assert {"can't be blank", _} = changeset.errors[:display_name]

    assert {:error, _} = ProfileStore.update_profile(named, %{"display_name" => "   "})
  end
end
