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

  # The admin console is first-party only → every count is scoped to a single tenant. `messages` has NO
  # reliable app_id (default tenant-zero, never set by inserts), so message counts route through the parent
  # CONVERSATION's app_id. Direct-app_id tables (users_auth, conversations, media_assets) filter in place.
  # A nil app_id defaults to tenant-zero (fail-closed to first-party; the console always passes it).
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
            "SELECT count(*) FROM messages m " <>
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
            "SELECT count(DISTINCT m.conversation_id) FROM messages m " <>
              "JOIN conversations c ON c.id = m.conversation_id " <>
              "WHERE c.app_id = $1 AND m.created_at >= now() - interval '7 days'",
            p
          )
      },
      auth: login_counts_7d()
    }
  end

  # messages routed through the conversation for the tenant predicate (messages.app_id is unreliable).
  defp recent_messages_sql(window) do
    "SELECT count(*) FROM messages m JOIN conversations c ON c.id = m.conversation_id " <>
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
      FROM messages m JOIN conversations conv ON conv.id = m.conversation_id
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
