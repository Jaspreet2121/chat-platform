defmodule AuthService.ModerationUsernameHoldTest do
  @moduledoc """
  Account-deletion × usernames (`@tag :postgres_integration`): the admin HARD delete cascades the profile
  row away, which would FREE the handle instantly — the same impersonation vector the rename hold closes
  (delete → someone else immediately becomes you). The delete transaction therefore writes the SAME
  30-day hold a rename writes. Proves: the hold row exists after deletion (30 days, keyed to the deleted
  user), and a deletion with NO username writes nothing.
  """
  use AuthService.DataCase, async: false

  alias AuthService.Moderation

  @tenant_zero "00000000-0000-0000-0000-000000000001"

  defp user!(opts \\ []) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, email, password_hash, role, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', $4, now(), now())",
      [id, @tenant_zero, "#{id}@test.local", opts[:role] || "user"]
    )

    id
  end

  defp profile!(user_id, username) do
    key = username && String.downcase(username)

    Repo.query!(
      "INSERT INTO user_profiles (user_id, display_name, app_id, username, username_key, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, 'Doomed', $2::text::uuid, $3, $4, now(), now())",
      [user_id, @tenant_zero, username, key]
    )
  end

  defp hold(username_key) do
    %{rows: rows} =
      Repo.query!(
        "SELECT user_id::text, (held_until > now() + interval '29 days') FROM username_holds " <>
          "WHERE app_id = $1::text::uuid AND username_key = $2",
        [@tenant_zero, username_key]
      )

    case rows do
      [[user_id, long_enough]] -> %{user_id: user_id, long_enough: long_enough}
      _ -> nil
    end
  end

  @tag :postgres_integration
  test "deleting an account with a username writes the 30-day hold (no instant release)" do
    actor = user!(role: "root")
    target = user!()
    profile!(target, "Famous_One")

    assert {:ok, _} = Moderation.delete_user(%{"user_id" => target, "actor_user_id" => actor})

    # The profile row cascaded away — but the handle is HELD, not freed, for the full window.
    assert %{user_id: ^target, long_enough: true} = hold("famous_one")

    %{rows: profile_rows} =
      Repo.query!("SELECT 1 FROM user_profiles WHERE user_id = $1::text::uuid", [target])

    assert profile_rows == []
  end

  @tag :postgres_integration
  test "deleting an account with NO username writes no hold" do
    actor = user!(role: "root")
    target = user!()
    profile!(target, nil)

    %{rows: [[before_count]]} = Repo.query!("SELECT count(*)::int FROM username_holds", [])
    assert {:ok, _} = Moderation.delete_user(%{"user_id" => target, "actor_user_id" => actor})
    %{rows: [[after_count]]} = Repo.query!("SELECT count(*)::int FROM username_holds", [])

    assert after_count == before_count
  end
end
