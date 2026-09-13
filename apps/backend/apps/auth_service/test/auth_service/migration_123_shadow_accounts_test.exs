defmodule AuthService.Migration123ShadowAccountsTest do
  @moduledoc """
  Migration 123 on real SQL: deletes a shadow account that nothing refers to; keeps — and only
  keeps — every row that is referenced, real, external, or newer than the cutoff; deletes nothing
  on a second run.
  """
  use AuthService.DataCase, async: false

  @tenant "00000000-0000-0000-0000-000000000001"
  @old "2026-08-01 12:00:00+00"

  defp user!(opts \\ []) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, external_id, status, created_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, $4, $5, $6::text::timestamptz)",
      [
        id,
        @tenant,
        Keyword.get(opts, :phone, "+1555#{System.unique_integer([:positive])}"),
        Keyword.get(opts, :external_id),
        Keyword.get(opts, :status, "active"),
        Keyword.get(opts, :created_at, @old)
      ]
    )

    id
  end

  defp session!(user_id) do
    Repo.query!(
      "INSERT INTO device_sessions (user_id, device_id, platform, refresh_token_hash) VALUES ($1::text::uuid, $2, 'android', 'x')",
      [user_id, "dev-" <> Integer.to_string(System.unique_integer([:positive]))]
    )
  end

  defp exists?(user_id) do
    %{rows: rows} = Repo.query!("SELECT 1 FROM users_auth WHERE id = $1::text::uuid", [user_id])
    rows != []
  end

  defp apply_123! do
    :shared_infra
    |> Application.app_dir("priv/schema")
    |> Path.join("123_delete_shadow_accounts.sql")
    |> File.read!()
    |> SharedInfra.Release.statements()
    |> Enum.reject(&(String.upcase(&1) in ["BEGIN", "COMMIT"]))
    |> Enum.each(&Repo.query!(&1, []))
  end

  @tag :postgres_integration
  test "deletes an unreferenced shadow; keeps referenced, real, external and post-cutoff rows; idempotent" do
    real = user!()
    session!(real)

    clean_shadow = user!()

    # A shadow that is a GROUP MEMBER — referenced by conversation_participants (a hard FK with
    # ON DELETE CASCADE, which is exactly why it must be excluded rather than deleted).
    member_shadow = user!()
    conv = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by) VALUES ($1::text::uuid, $2::text::uuid, 'group', $3::text::uuid)",
      [conv, @tenant, real]
    )

    Repo.query!(
      "INSERT INTO conversation_participants (conversation_id, user_id) VALUES ($1::text::uuid, $2::text::uuid)",
      [conv, member_shadow]
    )

    # A shadow referenced only by a SOFT column (message_receipts has no FK to users_auth).
    receipt_shadow = user!()

    Repo.query!(
      "INSERT INTO message_receipts (conversation_id, message_id, user_id, status, delivered_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, 'delivered', now())",
      [conv, Ecto.UUID.generate(), receipt_shadow]
    )

    # A v1 integrator end-user: no phone, no session, no profile — NOT a shadow.
    external = user!(phone: nil, external_id: "acme-alice")

    # Created after the cutoff — a verify possibly in flight.
    fresh_shadow = user!(created_at: "2026-09-13 09:00:00+00")

    apply_123!()

    refute exists?(clean_shadow), "the unreferenced shadow survived"

    assert exists?(member_shadow),
           "a shadow inside a conversation was DELETED — the cascade would have removed its membership row"

    assert exists?(receipt_shadow), "a shadow referenced by a soft column was deleted"
    assert exists?(external), "a v1 integrator end-user was deleted as a shadow"
    assert exists?(fresh_shadow), "a row newer than the cutoff was deleted"
    assert exists?(real)

    # AGAIN: nothing left to delete, nothing else touched.
    %{rows: [[before]]} = Repo.query!("SELECT count(*) FROM users_auth")
    apply_123!()
    %{rows: [[after_]]} = Repo.query!("SELECT count(*) FROM users_auth")
    assert after_ == before, "a second run deleted #{before - after_} row(s)"
  end
end
