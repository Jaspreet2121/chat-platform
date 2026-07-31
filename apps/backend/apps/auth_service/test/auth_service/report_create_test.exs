defmodule AuthService.ReportCreateTest do
  @moduledoc """
  `create_report` inserts into the EXISTING `user_reports` table so the admin console — `list_reports/1`,
  scoped by the reported user's `app_id` — surfaces the row with ZERO admin-side change. Real Postgres
  (`@tag :postgres_integration`). Proves the round-trip AND the FK guard on an unknown reported user.
  """
  use AuthService.DataCase, async: false

  alias AuthService.Moderation

  @tag :postgres_integration
  test "a created report is visible to the admin list_reports for the same tenant, status 'open'" do
    app = seed_app!()
    reporter = seed_user(app)
    reported = seed_user(app)

    assert {:ok, %{report_id: report_id}} =
             Moderation.create_report(%{
               "reporter_user_id" => reporter,
               "reported_user_id" => reported,
               "reason" => "spam",
               "details" => "unsolicited links"
             })

    assert is_binary(report_id)

    # The admin read — the SAME path the console uses, no change — sees the new row.
    assert {:ok, %{reports: reports}} = Moderation.list_reports(%{"app_id" => app})
    row = Enum.find(reports, &(&1.id == report_id))

    assert row
    assert row.reporter_user_id == reporter
    assert row.reported_user_id == reported
    assert row.reason == "spam"
    assert row.details == "unsolicited links"
    assert row.status == "open"
  end

  @tag :postgres_integration
  test "an unknown reported user → :report_invalid (FK), never a 500" do
    app = seed_app!()
    reporter = seed_user(app)

    assert {:error, :report_invalid} =
             Moderation.create_report(%{
               "reporter_user_id" => reporter,
               "reported_user_id" => Ecto.UUID.generate(),
               "reason" => "spam"
             })
  end

  # users_auth.app_id is FK-constrained to apps(id), so a bare Ecto.UUID.generate() tenant fails with
  # 23503 before the test reaches its assertion. The tenant row has to exist.
  defp seed_app! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO apps (id, name, slug) VALUES ($1::text::uuid, 'Report Test', $2)",
      [id, "rpt-" <> String.slice(String.replace(id, "-", ""), 0, 12)]
    )

    id
  end

  defp seed_user(app_id) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, email, password_hash, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', now(), now())",
      [id, app_id, "#{id}@test.local"]
    )

    id
  end
end
