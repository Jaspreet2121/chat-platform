defmodule UserService.EmailPrivacyTest do
  @moduledoc """
  EMAIL IS PRIVATE — the assertion that matters, because this leak would be SILENT: no error, no
  crash, just someone's address on a surface it was never meant to reach.

  Email lives on users_auth. Every OTHER-USER surface (the public profile card, by-phone, by-username,
  contacts sync) resolves through UserService.Profiles / ProfileStore, which read `user_profiles` and
  never join users_auth. This suite pins that structurally: whatever those reads return, `email` is
  not in it — so a future field addition to the profile shape cannot quietly carry it along.
  """
  use UserService.DataCase, async: false

  alias UserService.Profiles

  @tenant_zero "00000000-0000-0000-0000-000000000001"

  setup do
    previous = Application.get_env(:user_service, :user_profile_persistence, false)
    Application.put_env(:user_service, :user_profile_persistence, true)
    on_exit(fn -> Application.put_env(:user_service, :user_profile_persistence, previous) end)
    :ok
  end

  defp user_with_email! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, email, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, $4, 'active', now(), now())",
      [id, @tenant_zero, "+1555#{System.unique_integer([:positive])}", "private@example.com"]
    )

    {:ok, _} =
      Profiles.update_current_profile(%{"user_id" => id, "display_name" => "Has Email"})

    id
  end

  @tag :postgres_integration
  test "the PUBLIC profile card carries no email, under any key" do
    user_id = user_with_email!()

    {:ok, profile} =
      Profiles.get_public_profile(%{"user_id" => user_id, "app_id" => @tenant_zero})

    assert profile.display_name == "Has Email"
    refute_email_anywhere(profile)
  end

  @tag :postgres_integration
  test "the OWNER's own profile read (user_service half) also carries no email — it is composed at the gateway" do
    user_id = user_with_email!()

    {:ok, profile} = Profiles.get_current_profile(%{"user_id" => user_id})

    # user_service never reads users_auth. GET /users/me gets `email` from the SESSION at the gateway
    # (the caller's own row only), which is why no other-user surface can ever pick it up here.
    refute_email_anywhere(profile)
  end

  @tag :postgres_integration
  test "the USERNAME lookup carries no email" do
    user_id = user_with_email!()

    {:ok, _} =
      Profiles.update_current_profile(%{"user_id" => user_id, "username" => "emailhaver"})

    {:ok, found} =
      UserService.Usernames.lookup(%{
        "username" => "emailhaver",
        "app_id" => @tenant_zero
      })

    refute_email_anywhere(found)
  end

  # Structural, not field-by-field: ANY key or value mentioning the address fails, so a future
  # addition to the profile shape can't smuggle it in under a new name.
  defp refute_email_anywhere(payload) do
    serialised = inspect(payload)

    refute serialised =~ "private@example.com",
           "email LEAKED into a non-owner surface: #{serialised}"

    refute serialised =~ ~r/[^_a-z]email/,
           "an email-ish key appeared on a non-owner surface: #{serialised}"
  end
end
