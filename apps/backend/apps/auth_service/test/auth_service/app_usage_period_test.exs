defmodule AuthService.AppUsagePeriodTest do
  @moduledoc """
  The billing meter (`app_usage_period/1`) against real Postgres: calendar-month boundaries, sender-MAU,
  twin exclusion (by app_id construction), the messages.app_id trap, and call-seconds attribution.
  """
  use AuthService.DataCase, async: false

  @moduletag :postgres_integration

  alias AuthService.Apps

  # --- fixtures (raw SQL — these tables span services; one shared Postgres) ---

  defp app!(mode \\ "live", parent \\ nil) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO apps (id, name, slug, mode, parent_app_id, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2, $3, $4, $5::text::uuid, now(), now())",
      [id, "app-#{id}", "slug-#{id}", mode, parent]
    )

    id
  end

  defp user!(app_id) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, external_id, password_hash, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', now(), now())",
      [id, app_id, "ext-#{id}"]
    )

    id
  end

  defp conversation!(app_id, creator) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, type, created_by, status, app_id, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, 'group', $2::text::uuid, 'active', $3::text::uuid, now(), now())",
      [id, creator, app_id]
    )

    id
  end

  # Seeds the LIVE source (message_search — the meter's table since the re-point; frozen Postgres
  # `messages` is no longer consulted). The stamped_app_id param is kept-and-ignored deliberately:
  # message_search HAS no app_id column, so the old trap this suite proved ("a message stamped with
  # the wrong app_id counts under its conversation") is now STRUCTURAL — tenancy can only ride the
  # parent-conversation join, because there is no per-message app_id to mistrust.
  defp message!(conv, sender, at, _stamped_app_id) do
    Repo.query!(
      "INSERT INTO message_search (message_id, conversation_id, sender_user_id, created_at, search_text) " <>
        "VALUES (gen_random_uuid(), $1::text::uuid, $2::text::uuid, $3, 'x')",
      [conv, sender, at]
    )
  end

  defp call!(caller, callee, answered_at, ended_at) do
    Repo.query!(
      "INSERT INTO calls (id, room_name, caller_id, callee_id, type, status, created_at, answered_at, ended_at) " <>
        "VALUES (gen_random_uuid(), $1, $2::text::uuid, $3::text::uuid, 'voice', $4, now(), $5, $6)",
      [
        "room-#{Ecto.UUID.generate()}",
        caller,
        callee,
        if(answered_at, do: "ended", else: "missed"),
        answered_at,
        ended_at
      ]
    )
  end

  defp media!(app_id, owner, bytes) do
    Repo.query!(
      "INSERT INTO media_assets (id, owner_user_id, app_id, purpose, storage_provider, bucket, object_key, mime_type, size_bytes, status, created_at, updated_at) " <>
        "VALUES (gen_random_uuid(), $1::text::uuid, $2::text::uuid, 'message', 'minio', 'b', $3, 'image/png', $4, 'ready', now(), now())",
      [owner, app_id, "k-#{Ecto.UUID.generate()}", bytes]
    )
  end

  defp usage!(app_id, period) do
    {:ok, usage} = Apps.app_usage_period(%{"app_id" => app_id, "period" => period})
    usage
  end

  defp dt(iso), do: (fn {:ok, d, _} -> d end).(DateTime.from_iso8601(iso))

  # --- tests ---

  test "MONTH BOUNDARIES: start inclusive, next-month-start exclusive — one message either side of each" do
    app = app!()
    u = user!(app)
    conv = conversation!(app, u)

    message!(conv, u, dt("2026-06-30T23:59:59Z"), app)
    message!(conv, u, dt("2026-07-01T00:00:00Z"), app)
    message!(conv, u, dt("2026-07-15T12:00:00Z"), app)

    # The next-month-start boundary can't be seeded in the future (2026-08-01 > today) without lying to the
    # meter — so prove exclusivity on JUNE instead: June counts exactly the 06-30 message, not July's.
    june = usage!(app, "2026-06")
    july = usage!(app, "2026-07")

    assert june.messages_sent == 1
    assert july.messages_sent == 2
    assert july.period_start == "2026-07-01T00:00:00Z"
    assert july.period_end == "2026-08-01T00:00:00Z"
  end

  test "sender-MAU: 3 senders × several messages → 3; other-app and twin senders excluded" do
    app = app!()
    twin = app!("test", app)
    other = app!()

    [a, b, c] = [user!(app), user!(app), user!(app)]
    conv = conversation!(app, a)
    for u <- [a, b, c], _ <- 1..3, do: message!(conv, u, dt("2026-07-05T10:00:00Z"), app)

    # Twin traffic (a test key's data lives under the TWIN's app_id — 054's by-app_id isolation).
    tu = user!(twin)
    tconv = conversation!(twin, tu)
    message!(tconv, tu, dt("2026-07-05T10:00:00Z"), twin)

    # Another live app entirely.
    ou = user!(other)
    oconv = conversation!(other, ou)
    message!(oconv, ou, dt("2026-07-05T10:00:00Z"), other)

    assert usage!(app, "2026-07").active_users_by_messages == 3

    # …and the twin's own meter sees ITS user — proving isolation is by app_id, not by absence of data.
    assert usage!(twin, "2026-07").active_users_by_messages == 1
  end

  test "THE TRAP: a message stamped with the WRONG app_id counts under its CONVERSATION's app" do
    app = app!()
    other = app!()
    u = user!(app)
    conv = conversation!(app, u)

    # The row LIES about its tenant; the parent-conversation join must not care.
    message!(conv, u, dt("2026-07-05T10:00:00Z"), other)

    assert usage!(app, "2026-07").messages_sent == 1
    assert usage!(other, "2026-07").messages_sent == 0
  end

  test "CALL SECONDS: answered duration sums; missed → 0; boundary-spanning bills to the ANSWERED month" do
    app = app!()
    caller = user!(app)
    callee = user!(app)

    # 90 seconds, cleanly inside July.
    call!(caller, callee, dt("2026-07-10T10:00:00Z"), dt("2026-07-10T10:01:30Z"))
    # Missed — never answered.
    call!(caller, callee, nil, dt("2026-07-10T11:00:00Z"))
    # Spans the June→July boundary: answered June 30 23:59:00, ended July 1 00:01:00 (120s) —
    # attributed ENTIRELY to June (the month of answered_at).
    call!(caller, callee, dt("2026-06-30T23:59:00Z"), dt("2026-07-01T00:01:00Z"))

    assert usage!(app, "2026-07").call_seconds == 90
    assert usage!(app, "2026-06").call_seconds == 120
  end

  test "storage is a SNAPSHOT (period-independent) and twin media stays under the twin" do
    app = app!()
    twin = app!("test", app)
    u = user!(app)
    tu = user!(twin)

    media!(app, u, 1000)
    media!(twin, tu, 999_999)

    # Same snapshot whatever the month; the twin's bytes never leak into the live app's meter.
    assert usage!(app, "2026-06").storage_bytes_snapshot == 1000
    assert usage!(app, "2026-07").storage_bytes_snapshot == 1000
    assert usage!(twin, "2026-07").storage_bytes_snapshot == 999_999
  end

  test "validation: malformed and not-yet-started periods → :invalid_period; pre-creation month → zeros" do
    app = app!()

    for bad <- ["2026-13", "garbage", "26-07", "2026-7", "2999-01"] do
      assert {:error, :invalid_period} =
               Apps.app_usage_period(%{"app_id" => app, "period" => bad}),
             "expected #{bad} to be rejected"
    end

    # Before the app existed: a legitimate month, just empty.
    empty = usage!(app, "2025-01")
    assert empty.messages_sent == 0
    assert empty.active_users_by_messages == 0
    assert empty.call_seconds == 0
  end
end
