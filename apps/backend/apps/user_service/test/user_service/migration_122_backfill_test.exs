defmodule UserService.Migration122BackfillTest do
  @moduledoc """
  Migration 122 on real SQL: it gives a profile row to every REAL active account that has none —
  real meaning "has ever completed an OTP verify", i.e. has a device_sessions row — and to nobody
  else, and running it twice adds nothing.

  The test seeds the exact prod shape (a real user without a card, a shadow account, a suspended
  account with a session, a user who already has a card) and applies the file's statements twice.
  """
  use UserService.DataCase, async: false

  @tenant "00000000-0000-0000-0000-000000000001"

  defp user!(status \\ "active") do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, status) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, $4)",
      [id, @tenant, "+1555#{System.unique_integer([:positive])}", status]
    )

    id
  end

  defp session!(user_id) do
    Repo.query!(
      "INSERT INTO device_sessions (user_id, device_id, platform, refresh_token_hash) " <>
        "VALUES ($1::text::uuid, $2, 'android', 'x')",
      [user_id, "dev-" <> Integer.to_string(System.unique_integer([:positive]))]
    )
  end

  defp profile_row(user_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT display_name, app_id::text FROM user_profiles WHERE user_id = $1::text::uuid",
        [user_id]
      )

    rows
  end

  # The file's statements minus BEGIN/COMMIT (the sandbox holds the transaction). The DO $$ block
  # is ONE statement to the splitter — the 048/073 precedent.
  defp apply_122! do
    :shared_infra
    |> Application.app_dir("priv/schema")
    |> Path.join("122_user_profiles_for_every_real_user.sql")
    |> File.read!()
    |> SharedInfra.Release.statements()
    |> Enum.reject(&(String.upcase(&1) in ["BEGIN", "COMMIT"]))
    |> Enum.each(&Repo.query!(&1, []))
  end

  @tag :postgres_integration
  test "backfills real users without a card, skips shadows and non-active, and is idempotent" do
    real = user!()
    session!(real)

    shadow = user!()

    suspended = user!("suspended")
    session!(suspended)

    has_card = user!()
    session!(has_card)

    Repo.query!(
      "INSERT INTO user_profiles (user_id, app_id, display_name) VALUES ($1::text::uuid, $2::text::uuid, 'Kept')",
      [has_card, @tenant]
    )

    apply_122!()

    assert [[nil, @tenant]] = profile_row(real),
           "a real user (active, has a session) did not get a card"

    assert profile_row(shadow) == [],
           "a SHADOW account (never a session) was given a card — it must be left exactly as it was"

    assert profile_row(suspended) == []
    assert [["Kept", _]] = profile_row(has_card), "an existing card was touched"

    # AGAIN. A second application must add nothing and change nothing.
    apply_122!()

    assert [[nil, @tenant]] = profile_row(real)
    assert profile_row(shadow) == []
    assert [["Kept", _]] = profile_row(has_card)

    %{rows: [[total]]} =
      Repo.query!(
        "SELECT count(*) FROM user_profiles WHERE user_id IN ($1::text::uuid, $2::text::uuid, $3::text::uuid, $4::text::uuid)",
        [real, shadow, suspended, has_card]
      )

    assert total == 2
  end
end
