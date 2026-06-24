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

  @doc "Totals + recent activity for the dashboard top cards (one map, a handful of grouped queries)."
  def overview do
    %{
      totals: %{
        users: scalar("SELECT count(*) FROM users_auth"),
        conversations: scalar("SELECT count(*) FROM conversations"),
        messages: scalar("SELECT count(*) FROM messages"),
        media: scalar("SELECT count(*) FROM media_assets"),
        storage_bytes: scalar("SELECT COALESCE(SUM(size_bytes), 0)::bigint FROM media_assets")
      },
      activity: %{
        messages_24h:
          scalar("SELECT count(*) FROM messages WHERE created_at >= now() - interval '24 hours'"),
        messages_7d:
          scalar("SELECT count(*) FROM messages WHERE created_at >= now() - interval '7 days'"),
        active_conversations_7d:
          scalar(
            "SELECT count(DISTINCT conversation_id) FROM messages " <>
              "WHERE created_at >= now() - interval '7 days'"
          )
      },
      auth: login_counts_7d()
    }
  end

  @doc "Per-day series (signups, messages, conversations) over the last `days`, gap-filled."
  def timeseries(days) do
    bounded = days |> normalize_days()

    %{
      days: bounded,
      signups: daily_series("users_auth", bounded),
      messages: daily_series("messages", bounded),
      conversations: daily_series("conversations", bounded)
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

  defp scalar(sql) do
    %Postgrex.Result{rows: [[value]]} = Repo.query!(sql)
    value || 0
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

  # `table` is always a hard-coded constant from this module — never user input.
  defp daily_series(table, days) do
    sql = """
    SELECT to_char(g, 'YYYY-MM-DD') AS date, COALESCE(c.cnt, 0)::int AS count
    FROM generate_series((now()::date - ($1::int - 1)), now()::date, interval '1 day') g
    LEFT JOIN (
      SELECT date_trunc('day', created_at)::date AS d, count(*) AS cnt
      FROM #{table}
      WHERE created_at >= (now()::date - ($1::int - 1))
      GROUP BY d
    ) c ON c.d = g::date
    ORDER BY date
    """

    %Postgrex.Result{rows: rows} = Repo.query!(sql, [days])
    Enum.map(rows, fn [date, count] -> %{date: date, count: count} end)
  end
end
