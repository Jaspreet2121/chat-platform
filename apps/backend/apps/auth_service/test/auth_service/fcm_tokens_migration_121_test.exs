defmodule AuthService.FcmTokensMigration121Test do
  @moduledoc """
  Migration 121 on real SQL: it dedups to the NEWEST row per (user_id, device_id), drops NULL-device
  rows, makes the column NOT NULL, creates the device key — and does all of it AGAIN without error,
  because the deploy runbook applies schema files by hand and a second run must be a safe no-op.

  The test DB already carries 121 (the gate loads every file), so the test first UNDOES its
  effects inside the sandbox transaction, seeds the exact prod shape (a collision + a NULL), then
  applies the file's statements twice. DDL is transactional in Postgres; the sandbox rolls it all
  back.
  """
  use AuthService.DataCase, async: false

  alias AuthService.Repo

  @user "64444444-4444-4444-8444-444444444444"

  @tag :postgres_integration
  test "dedups to the newest row, enforces NOT NULL + the device key, and is idempotent" do
    Repo.query!(
      "INSERT INTO users_auth (id, phone_number) VALUES ($1::text::uuid, $2) ON CONFLICT DO NOTHING",
      [@user, "+916444444444"]
    )

    # Undo 121 so the pre-migration shape can be seeded.
    Repo.query!("DROP INDEX IF EXISTS fcm_tokens_user_device_key")
    Repo.query!("ALTER TABLE fcm_tokens ALTER COLUMN device_id DROP NOT NULL")

    # THE PROD SHAPE (13 Sep): one device with two token rows (a rotation), plus a NULL-device row.
    insert!("older-token", "android-poco", "2026-08-26 00:00:00+00")
    insert!("newer-token", "android-poco", "2026-09-10 00:00:00+00")
    insert!("orphan-token", nil, "2026-09-01 00:00:00+00")
    assert count_all() == 3

    apply_121!()

    assert tokens_for("android-poco") == ["newer-token"],
           "dedup kept the wrong row — the live token must survive, not the rotated-away one"

    assert count_all() == 1, "the NULL-device row survived — SET NOT NULL would have failed"
    assert not_null?(), "device_id is still nullable"
    assert index?(), "the device key was not created"

    # RUN IT AGAIN. A hand-applied migration that is not idempotent is a 3am incident waiting on the
    # second `psql -f`.
    apply_121!()

    assert count_all() == 1
    assert not_null?()
    assert index?()
  end

  # --- helpers --------------------------------------------------------------------------------------

  # The file's statements, minus BEGIN/COMMIT: the sandbox already holds a transaction, and a COMMIT
  # inside it would commit the sandbox itself. Everything else runs verbatim.
  defp apply_121! do
    path =
      :shared_infra
      |> Application.app_dir("priv/schema")
      |> Path.join("121_fcm_tokens_one_row_per_device.sql")

    path
    |> File.read!()
    |> SharedInfra.Release.statements()
    |> Enum.reject(&(String.upcase(&1) in ["BEGIN", "COMMIT"]))
    |> Enum.each(&Repo.query!(&1, []))
  end

  defp insert!(token, device_id, updated_at) do
    Repo.query!(
      "INSERT INTO fcm_tokens (user_id, token, device_id, updated_at) " <>
        "VALUES ($1::text::uuid, $2, $3, $4::text::timestamptz)",
      [@user, token, device_id, updated_at]
    )
  end

  defp count_all do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM fcm_tokens WHERE user_id = $1::text::uuid", [@user])

    n
  end

  defp tokens_for(device_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT token FROM fcm_tokens WHERE user_id = $1::text::uuid AND device_id = $2",
        [@user, device_id]
      )

    Enum.map(rows, fn [t] -> t end)
  end

  defp not_null? do
    %{rows: [[nullable]]} =
      Repo.query!(
        "SELECT is_nullable FROM information_schema.columns " <>
          "WHERE table_name = 'fcm_tokens' AND column_name = 'device_id'"
      )

    nullable == "NO"
  end

  defp index? do
    %{rows: rows} =
      Repo.query!(
        "SELECT indexdef FROM pg_indexes WHERE tablename = 'fcm_tokens' " <>
          "AND indexname = 'fcm_tokens_user_device_key'"
      )

    match?([[def]] when is_binary(def), rows) and
      hd(hd(rows)) =~ "UNIQUE INDEX" and hd(hd(rows)) =~ "(user_id, device_id)"
  end
end
