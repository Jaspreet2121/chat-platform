defmodule MessageService.Analytics do
  @moduledoc """
  Read-only admin analytics over the shared Postgres.

  Lives in message_service purely because it already owns a Postgres `Repo` on the shared database and
  an internal HTTP API the gateway calls — analytics legitimately reads ACROSS domains (users,
  conversations, messages, media, login_attempts), and they all live in one physical DB. A dedicated
  analytics_service would be the textbook home, but that's a whole app + container for read-only
  queries. Every function here is SELECT-only (no writes) and uses single grouped queries against the
  existing indexes (no N+1). Table names are hard-coded constants — never interpolate user input.
  """

  alias MessageService.Repo

  # The admin console is first-party only → every count is scoped to a single tenant. Message counts
  # come from message_search — the live store's copy (DECISION_LOG 2026-08-09 drop-blockers #3): the
  # Postgres `messages` table froze at the scylla cutover, so every windowed number here has read 0
  # and every total was stuck since 2026-08-08. message_search has NO app_id column, so tenancy rides
  # the parent CONVERSATION's app_id — which was already the rule when `messages` was the source (its
  # app_id was untrusted); now it is structural. Semantics: live non-deleted indexed messages —
  # deleted messages leave these numbers (recorded delta, same as the admin conversation counts).
  # If the search consumer is ever off the counts go stale, never zero — search's own 503 is the
  # loud canary. A nil app_id defaults to tenant-zero (fail-closed to first-party).
  @doc "Totals + recent activity for the dashboard top cards (one map, a handful of grouped queries)."
  def overview(app_id \\ nil) do
    app = SharedInfra.Tenancy.app_id_or_default(app_id)
    p = [uuid_param(app)]

    %{
      totals: %{
        users: scalar("SELECT count(*) FROM users_auth WHERE app_id = $1", p),
        conversations: scalar("SELECT count(*) FROM conversations WHERE app_id = $1", p),
        messages:
          scalar(
            "SELECT count(*) FROM message_search m " <>
              "JOIN conversations c ON c.id = m.conversation_id WHERE c.app_id = $1",
            p
          ),
        media: scalar("SELECT count(*) FROM media_assets WHERE app_id = $1", p),
        storage_bytes:
          scalar(
            "SELECT COALESCE(SUM(size_bytes), 0)::bigint FROM media_assets WHERE app_id = $1",
            p
          )
      },
      activity: %{
        messages_24h: scalar(recent_messages_sql("24 hours"), p),
        messages_7d: scalar(recent_messages_sql("7 days"), p),
        active_conversations_7d:
          scalar(
            "SELECT count(DISTINCT m.conversation_id) FROM message_search m " <>
              "JOIN conversations c ON c.id = m.conversation_id " <>
              "WHERE c.app_id = $1 AND m.created_at >= now() - interval '7 days'",
            p
          )
      },
      auth: login_counts_7d(),
      # Part 2 dashboard additions. Everything here is a COUNT — no names, no coordinates, no rows.
      # `nearby_opted_in` in particular is deliberately a single scalar: the console never learns who
      # is visible or where, only how many chose to be.
      users: user_mix(p),
      sessions: active_sessions_by_platform(p),
      moderation: %{reports_open: scalar(open_reports_sql(), p)},
      dating: dating_counts(p),
      nearby: %{
        opted_in_now:
          scalar(
            "SELECT count(*) FROM nearby_presence WHERE app_id = $1 AND expires_at > now()",
            p
          )
      },
      messages_today:
        scalar(
          "SELECT count(*) FROM message_search m JOIN conversations c ON c.id = m.conversation_id " <>
            "WHERE c.app_id = $1 AND m.created_at >= date_trunc('day', now())",
          p
        )
    }
  end

  # "Real" vs "v1": a v1 user is one an integrating app resolved by external_id — it never signed up
  # here and has no phone or email of its own. Counting them together makes the user total meaningless
  # the first time a partner app backfills, so the dashboard splits them rather than showing one number
  # that silently changes meaning. Deleted users are excluded from both: a deleted row is retained for
  # the deletion audit, not for the headline count.
  defp user_mix(p) do
    %{
      real:
        scalar(
          "SELECT count(*) FROM users_auth WHERE app_id = $1 AND external_id IS NULL " <>
            "AND deleted_at IS NULL",
          p
        ),
      v1:
        scalar(
          "SELECT count(*) FROM users_auth WHERE app_id = $1 AND external_id IS NOT NULL " <>
            "AND deleted_at IS NULL",
          p
        )
    }
  end

  # Live sessions, split by platform. revoked_at IS NULL is the same liveness test logout and the
  # admin revoke use, so the dashboard and the revoke button can never disagree about what "active"
  # means. Tenancy rides the OWNING USER (device_sessions has no app_id).
  defp active_sessions_by_platform(p) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        "SELECT s.platform, count(*) FROM device_sessions s " <>
          "JOIN users_auth u ON u.id = s.user_id " <>
          "WHERE u.app_id = $1 AND s.revoked_at IS NULL GROUP BY s.platform",
        p
      )

    counts = Map.new(rows, fn [platform, n] -> {platform, n} end)

    # Every platform the CHECK constraint allows is reported, zero included — a missing key would
    # read as "no data" on the dashboard when it actually means "nobody is signed in on iOS".
    base = %{"android" => 0, "ios" => 0, "web" => 0}
    totals = Map.merge(base, counts)
    Map.put(totals, "total", Enum.sum(Map.values(totals)))
  end

  # user_reports has no app_id of its own; tenancy rides the REPORTER, who always exists.
  defp open_reports_sql do
    "SELECT count(*) FROM user_reports r JOIN users_auth u ON u.id = r.reporter_user_id " <>
      "WHERE u.app_id = $1 AND r.status IN ('open', 'reviewing')"
  end

  defp dating_counts(p) do
    %{
      matches_today:
        scalar(
          "SELECT count(*) FROM dating_matches WHERE app_id = $1 " <>
            "AND matched_at >= date_trunc('day', now())",
          p
        ),
      matches_7d:
        scalar(
          "SELECT count(*) FROM dating_matches WHERE app_id = $1 " <>
            "AND matched_at >= now() - interval '7 days'",
          p
        ),
      likes_today:
        scalar(
          "SELECT count(*) FROM dating_swipes WHERE app_id = $1 AND action = 'like' " <>
            "AND updated_at >= date_trunc('day', now())",
          p
        )
    }
  end

  # messages routed through the conversation for the tenant predicate (messages.app_id is unreliable).
  defp recent_messages_sql(window) do
    "SELECT count(*) FROM message_search m JOIN conversations c ON c.id = m.conversation_id " <>
      "WHERE c.app_id = $1 AND m.created_at >= now() - interval '#{window}'"
  end

  @doc "Per-day series (signups, messages, conversations) over the last `days`, gap-filled — tenant-scoped."
  def timeseries(days, app_id \\ nil) do
    bounded = days |> normalize_days()
    app = SharedInfra.Tenancy.app_id_or_default(app_id)

    %{
      days: bounded,
      signups: daily_series_app("users_auth", bounded, app),
      messages: daily_series_messages(bounded, app),
      conversations: daily_series_app("conversations", bounded, app)
    }
  end

  def normalize_days(days) when is_integer(days) and days > 0, do: min(days, 365)

  def normalize_days(days) when is_binary(days) do
    case Integer.parse(days) do
      {n, _} when n > 0 -> min(n, 365)
      _ -> 30
    end
  end

  def normalize_days(_), do: 30

  defp scalar(sql, params) do
    %Postgrex.Result{rows: [[value]]} = Repo.query!(sql, params)
    value || 0
  end

  # uuid columns need the 16-byte binary, not the string form.
  defp uuid_param(value) when is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, binary} -> binary
      :error -> value
    end
  end

  defp login_counts_7d do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        "SELECT success, count(*) FROM login_attempts " <>
          "WHERE created_at >= now() - interval '7 days' GROUP BY success"
      )

    Enum.reduce(rows, %{login_success_7d: 0, login_failure_7d: 0}, fn
      [true, n], acc -> %{acc | login_success_7d: n}
      [false, n], acc -> %{acc | login_failure_7d: n}
      _row, acc -> acc
    end)
  end

  # Direct-app_id tables (users_auth, conversations). `table` is a hard-coded constant — never user input.
  defp daily_series_app(table, days, app) do
    sql = """
    SELECT to_char(g, 'YYYY-MM-DD') AS date, COALESCE(c.cnt, 0)::int AS count
    FROM generate_series((now()::date - ($1::int - 1)), now()::date, interval '1 day') g
    LEFT JOIN (
      SELECT date_trunc('day', created_at)::date AS d, count(*) AS cnt
      FROM #{table}
      WHERE created_at >= (now()::date - ($1::int - 1)) AND app_id = $2
      GROUP BY d
    ) c ON c.d = g::date
    ORDER BY date
    """

    run_series(sql, [days, uuid_param(app)])
  end

  # messages routed through the parent conversation (messages.app_id is unreliable).
  defp daily_series_messages(days, app) do
    sql = """
    SELECT to_char(g, 'YYYY-MM-DD') AS date, COALESCE(c.cnt, 0)::int AS count
    FROM generate_series((now()::date - ($1::int - 1)), now()::date, interval '1 day') g
    LEFT JOIN (
      SELECT date_trunc('day', m.created_at)::date AS d, count(*) AS cnt
      FROM message_search m JOIN conversations conv ON conv.id = m.conversation_id
      WHERE m.created_at >= (now()::date - ($1::int - 1)) AND conv.app_id = $2
      GROUP BY d
    ) c ON c.d = g::date
    ORDER BY date
    """

    run_series(sql, [days, uuid_param(app)])
  end

  defp run_series(sql, params) do
    %Postgrex.Result{rows: rows} = Repo.query!(sql, params)
    Enum.map(rows, fn [date, count] -> %{date: date, count: count} end)
  end
end
