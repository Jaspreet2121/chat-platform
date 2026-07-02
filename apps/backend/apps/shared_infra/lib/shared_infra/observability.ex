defmodule SharedInfra.Observability do
  @moduledoc """
  App-level observability store (Layers 2 & 3): error capture + per-app request metrics. Self-contained
  (Postgres only), STRUCTURED, per-app_id, correlation-id keyed — a future Grafana/Datadog/Sentry consumes
  this data without rework; it does not replace it.

  Parameterized by a raw `Postgrex` connection name (the gateway owns one — `ApiGateway.ObservabilityDB`),
  mirroring the Repo-parameterized `WebhookOutbox`. Everything is **fail-open**: if the connection isn't
  running (e.g. no DATABASE_URL in dev/test) or any query errors, writes no-op and reads return empty — an
  observability failure must NEVER break the actual request.
  """

  require Logger

  @query_timeout 2_000

  @doc """
  Record an error occurrence (best-effort). `attrs` keys: correlation_id, app_id, actor, method, route,
  status, error_class, message. Returns :ok always (fail-open).
  """
  def record_error(conn, attrs) when is_map(attrs) do
    with_conn(conn, fn ->
      Postgrex.query!(
        conn,
        "INSERT INTO observability_errors " <>
          "(correlation_id, app_id, actor, method, route, status, error_class, message) " <>
          "VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
        [
          s(attrs[:correlation_id]),
          s(attrs[:app_id]),
          s(attrs[:actor]),
          s(attrs[:method]),
          s(attrs[:route]),
          i(attrs[:status]),
          s(attrs[:error_class]),
          s(attrs[:message]) |> truncate(2000)
        ],
        timeout: @query_timeout
      )
    end)
  end

  @doc "Increment the per-(app_id, route, hour-bucket) request counter (best-effort). Returns :ok."
  def incr_request(conn, app_id, route) do
    with_conn(conn, fn ->
      Postgrex.query!(
        conn,
        "INSERT INTO observability_request_metrics (app_id, route, bucket, count) " <>
          "VALUES ($1, $2, date_trunc('hour', now()), 1) " <>
          "ON CONFLICT (app_id, route, bucket) DO UPDATE SET count = observability_request_metrics.count + 1",
        [s(app_id) || "unknown", s(route) || "unknown"],
        timeout: @query_timeout
      )
    end)
  end

  @doc """
  Per-app usage metrics for the admin surface. Returns a map:
    %{requests: [%{app_id, route, count}], webhooks_delivered: [%{app_id, count}], errors: [%{app_id, count}]}
  Aggregated over the last `hours` (default 24). Fail-open: returns empty lists on any failure.
  """
  def metrics(conn, opts \\ []) do
    hours = Keyword.get(opts, :hours, 24)

    %{
      requests: query_rows(conn, request_counts_sql(hours), [], &request_row/1),
      webhooks_delivered: query_rows(conn, webhook_delivered_sql(), [], &count_row/1),
      errors: query_rows(conn, error_counts_sql(hours), [], &count_row/1)
    }
  end

  # --- SQL ------------------------------------------------------------------------------------

  defp request_counts_sql(hours),
    do:
      "SELECT app_id, route, sum(count)::bigint FROM observability_request_metrics " <>
        "WHERE bucket >= now() - make_interval(hours => #{intval(hours)}) " <>
        "GROUP BY app_id, route ORDER BY app_id, route"

  defp error_counts_sql(hours),
    do:
      "SELECT app_id, count(*)::bigint FROM observability_errors " <>
        "WHERE inserted_at >= now() - make_interval(hours => #{intval(hours)}) " <>
        "GROUP BY app_id ORDER BY app_id"

  # Webhook deliveries are not gateway requests; read the delivered rows straight from the outbox.
  defp webhook_delivered_sql,
    do:
      "SELECT app_id::text, count(*)::bigint FROM webhook_outbox " <>
        "WHERE status = 'delivered' GROUP BY app_id ORDER BY app_id"

  defp request_row([app_id, route, count]), do: %{app_id: app_id, route: route, count: count}
  defp count_row([app_id, count]), do: %{app_id: app_id, count: count}

  # --- helpers (fail-open) --------------------------------------------------------------------

  # Run `fun` only if the Postgrex conn process is alive; swallow ALL errors → :ok.
  defp with_conn(conn, fun) do
    if is_atom(conn) and is_pid(Process.whereis(conn)) do
      fun.()
    end

    :ok
  rescue
    error ->
      Logger.debug("[observability] write skipped: #{Exception.message(error)}")
      :ok
  catch
    _kind, _reason -> :ok
  end

  defp query_rows(conn, sql, params, mapper) do
    if is_atom(conn) and is_pid(Process.whereis(conn)) do
      %Postgrex.Result{rows: rows} = Postgrex.query!(conn, sql, params, timeout: @query_timeout)
      Enum.map(rows, mapper)
    else
      []
    end
  rescue
    _error -> []
  catch
    _kind, _reason -> []
  end

  defp s(nil), do: nil
  defp s(v) when is_binary(v), do: v
  defp s(v) when is_atom(v), do: Atom.to_string(v)
  defp s(v), do: to_string(v)

  defp i(v) when is_integer(v), do: v
  defp i(_), do: nil

  defp truncate(nil, _n), do: nil
  defp truncate(str, n) when is_binary(str), do: binary_part(str, 0, min(byte_size(str), n))

  defp intval(v) when is_integer(v) and v > 0, do: v
  defp intval(_), do: 24
end
