defmodule MessageService.AnalyticsDashboardCountsTest do
  @moduledoc """
  The v1 admin dashboard replaced three link cards with real numbers. A number on a dashboard is
  worse than no number when it is wrong, because nobody re-derives it — so each count here is pinned
  to the predicate that gives it its meaning:

    * "real" users are the ones who signed up HERE (external_id IS NULL). Drop that predicate and a
      partner-app backfill silently inflates the headline user count.
    * "active" sessions mean revoked_at IS NULL — the same liveness test logout and the admin revoke
      button use. Drop it and the dashboard keeps counting sessions it already killed.
    * nearby opted-in counts only presence that has not EXPIRED, and only ever as a scalar. Drop the
      expiry predicate and the console reports people as visible who are not.
  """
  use MessageService.DataCase, async: false

  alias MessageService.Analytics

  @tenant "00000000-0000-0000-0000-000000000001"

  defp user!(opts \\ []) do
    id = Ecto.UUID.generate()
    external = Keyword.get(opts, :external_id)

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, external_id, status) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, $4, 'active')",
      [id, @tenant, "+1555#{System.unique_integer([:positive])}", external]
    )

    id
  end

  defp session!(user_id, platform, opts \\ []) do
    revoked = Keyword.get(opts, :revoked, false)

    Repo.query!(
      "INSERT INTO device_sessions (user_id, device_id, platform, refresh_token_hash, revoked_at) " <>
        "VALUES ($1::text::uuid, $2, $3, 'x', #{if revoked, do: "now()", else: "NULL"})",
      [user_id, "dev-#{System.unique_integer([:positive])}", platform]
    )
  end

  @tag :postgres_integration
  test "real and v1 users are counted separately, never as one total" do
    real = user!()
    _v1 = user!(external_id: "partner-#{System.unique_integer([:positive])}")

    %{users: users} = Analytics.overview(@tenant)

    assert users.real >= 1
    assert users.v1 >= 1

    before = users.real
    _another_v1 = user!(external_id: "partner-#{System.unique_integer([:positive])}")

    # THE point of the split: adding a v1 user must not move the "real" number at all.
    assert Analytics.overview(@tenant).users.real == before
    assert is_binary(real)
  end

  @tag :postgres_integration
  test "active sessions count live sessions only, and report every platform" do
    user = user!()
    session!(user, "ios")
    session!(user, "android")

    %{sessions: sessions} = Analytics.overview(@tenant)
    ios_before = sessions["ios"]
    total_before = sessions["total"]

    # A platform nobody is signed in on must read 0, not be missing.
    assert Map.has_key?(sessions, "web")

    other = user!()
    session!(other, "ios", revoked: true)

    after_revoked = Analytics.overview(@tenant).sessions
    assert after_revoked["ios"] == ios_before
    assert after_revoked["total"] == total_before
  end

  @tag :postgres_integration
  test "nearby opted-in is a single live count — no rows, no expired presence" do
    live = user!()
    stale = user!()

    Repo.query!(
      "INSERT INTO nearby_presence (user_id, app_id, latitude, longitude, accuracy_m, expires_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 1.0, 2.0, 10, now() + interval '1 hour')",
      [live, @tenant]
    )

    %{nearby: nearby} = Analytics.overview(@tenant)
    assert is_integer(nearby.opted_in_now)
    assert nearby.opted_in_now >= 1
    # The whole surface is one number: no list of users, no coordinates anywhere in the payload.
    assert Map.keys(nearby) == [:opted_in_now]
    with_live = nearby.opted_in_now

    Repo.query!(
      "INSERT INTO nearby_presence (user_id, app_id, latitude, longitude, accuracy_m, expires_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 1.0, 2.0, 10, now() - interval '1 hour')",
      [stale, @tenant]
    )

    assert Analytics.overview(@tenant).nearby.opted_in_now == with_live
  end

  @tag :postgres_integration
  test "dating and moderation counts are present and windowed" do
    a = user!()
    b = user!()
    [low, high] = Enum.sort([a, b])

    Repo.query!(
      "INSERT INTO dating_matches (app_id, user_low_id, user_high_id) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid)",
      [@tenant, low, high]
    )

    Repo.query!(
      "INSERT INTO dating_swipes (app_id, swiper_id, target_id, action) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, 'like')",
      [@tenant, a, b]
    )

    Repo.query!(
      "INSERT INTO user_reports (reporter_user_id, reported_user_id, reason, status) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'spam', 'open')",
      [a, b]
    )

    overview = Analytics.overview(@tenant)

    assert overview.dating.matches_today >= 1
    assert overview.dating.matches_7d >= overview.dating.matches_today
    assert overview.dating.likes_today >= 1
    assert overview.moderation.reports_open >= 1
    assert is_integer(overview.messages_today)
  end
end
