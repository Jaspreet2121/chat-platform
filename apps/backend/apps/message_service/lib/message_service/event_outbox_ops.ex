defmodule MessageService.EventOutboxOps do
  @moduledoc """
  READ-plus-acknowledge operator surface over `kafka_event_outbox` (096) — the observability half
  of the event outbox, following the webhook dead-letter ops precedent one service over.

  THE SURFACE OBSERVES; THE RELAY IS THE ONLY PUBLISHER. Nothing here can cause a row to publish:
  `acknowledge/1` is the single mutation and it moves `aborted -> acknowledged` ONLY (WHERE-guarded
  one-way), a state the relay cannot see — its two queries select `pending` and `staged` alone.
  Never a retry, never a republish: republishing an aborted row is a phantom event for a message
  that does not exist (the outbox slice's mutation (d) proved that red). Acknowledged rows KEEP
  `last_error` — the evidence survives filing; the row is archived, not erased.

  `summary/0` is the health check where ZEROS MEAN HEALTH (published rows are deleted on broker
  ack, so an empty table is the system working). `staged_max_age_seconds` is also the relay-health
  proxy: staged older than ~90s (stale window 60s + sweep interval 30s) means the relay is not
  resolving — down, or the store is unreachable and rows are deliberately `left`.

  The stored envelope is DISPLAYABLE because the payload is thin by design (ids only — the topic's
  founding privacy decision); it is still returned only by the single-row `get/1` expand, never in
  lists. If a fat-payload event type is ever added, revisit before its envelope reaches any UI.
  """

  alias MessageService.Repo

  @list_limit_default 30
  @list_limit_max 100

  @doc "Per-state counts and max ages. Zeros mean health."
  def summary(_attrs \\ %{}) do
    %{rows: rows} =
      Repo.query!(
        "SELECT status, count(*)::int, " <>
          "COALESCE(EXTRACT(EPOCH FROM (now() - min(created_at)))::bigint, 0) " <>
          "FROM kafka_event_outbox GROUP BY status",
        []
      )

    by_status = Map.new(rows, fn [status, count, age] -> {status, {count, age}} end)

    {staged_count, staged_age} = Map.get(by_status, "staged", {0, 0})
    {pending_count, pending_age} = Map.get(by_status, "pending", {0, 0})
    {aborted_count, _} = Map.get(by_status, "aborted", {0, 0})
    {acked_count, _} = Map.get(by_status, "acknowledged", {0, 0})

    {:ok,
     %{
       staged: %{count: staged_count, max_age_seconds: staged_age},
       pending: %{count: pending_count, max_age_seconds: pending_age},
       aborted: %{count: aborted_count},
       acknowledged: %{count: acked_count}
     }}
  end

  @doc """
  Keyset-paginated rows for one state (the webhook failed-list shape). METADATA ONLY — the
  envelope is behind the single-row `get/1` expand.
  """
  def list(attrs) do
    with {:ok, status} <- valid_status(attrs) do
      limit = attrs |> Map.get("limit") |> normalize_limit()
      {cursor_ts, cursor_id} = {Map.get(attrs, "cursor_ts"), Map.get(attrs, "cursor_id")}

      {cursor_sql, params} =
        if cursor_ts && cursor_id do
          {"AND (created_at, id) < ($2, $3::text::uuid) ", [status, cursor_ts, cursor_id]}
        else
          {"", [status]}
        end

      %{rows: rows} =
        Repo.query!(
          "SELECT id::text, event_type, conversation_id::text, message_id::text, status, " <>
            "attempts, last_error, created_at " <>
            "FROM kafka_event_outbox WHERE status = $1 " <>
            cursor_sql <>
            "ORDER BY created_at DESC, id DESC LIMIT #{limit}",
          params
        )

      items = Enum.map(rows, &row_map/1)

      next_cursor =
        case List.last(items) do
          %{created_at: ts, id: id} when length(items) == limit -> %{ts: ts, id: id}
          _ -> nil
        end

      {:ok, %{items: items, count: length(items), next_cursor: next_cursor}}
    end
  end

  @doc """
  One row WITH its envelope — the explicit expand. Rides the same view permission as the lists
  (it is a read; the expand itself is the envelope-visibility gate, not a higher permission). Safe
  to show because the payload is thin by design — ids, never message content.
  """
  def get(attrs) do
    with {:ok, id} <- required(attrs, "id") do
      case Repo.query!(
             "SELECT id::text, event_type, conversation_id::text, message_id::text, status, " <>
               "attempts, last_error, created_at, envelope, topic, partition_key " <>
               "FROM kafka_event_outbox WHERE id = $1::text::uuid",
             [id]
           ) do
        %{rows: [row]} ->
          [
            id,
            event_type,
            conversation_id,
            message_id,
            status,
            attempts,
            last_error,
            created_at,
            envelope,
            topic,
            key
          ] =
            row

          {:ok,
           %{
             id: id,
             event_type: event_type,
             conversation_id: conversation_id,
             message_id: message_id,
             status: status,
             attempts: attempts,
             last_error: last_error,
             created_at: created_at,
             envelope: envelope,
             topic: topic,
             partition_key: key
           }}

        %{rows: []} ->
          {:error, :event_not_found}
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :event_invalid}
  end

  @doc """
  File an aborted incident: `aborted -> acknowledged`, ONE WAY, WHERE-guarded so no other state
  can ever be touched — and `acknowledged` is invisible to the relay's `pending`/`staged` queries,
  so a filed row can never re-enter the publish state machine (trap 1). `last_error` is preserved:
  the evidence survives filing. Idempotent-ish: acknowledging a non-aborted row is `:noop`.
  """
  def acknowledge(attrs) do
    with {:ok, id} <- required(attrs, "id") do
      %{num_rows: n} =
        Repo.query!(
          "UPDATE kafka_event_outbox SET status = 'acknowledged' " <>
            "WHERE id = $1::text::uuid AND status = 'aborted'",
          [id]
        )

      if n == 1 do
        {:ok, %{id: id, status: "acknowledged"}}
      else
        {:ok, %{id: id, status: "noop"}}
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :event_invalid}
  end

  defp row_map([
         id,
         event_type,
         conversation_id,
         message_id,
         status,
         attempts,
         last_error,
         created_at
       ]) do
    %{
      id: id,
      event_type: event_type,
      conversation_id: conversation_id,
      message_id: message_id,
      status: status,
      attempts: attempts,
      last_error: last_error,
      created_at: created_at
    }
  end

  defp valid_status(attrs) do
    case Map.get(attrs, "status") do
      status when status in ["staged", "pending", "aborted", "acknowledged"] -> {:ok, status}
      _ -> {:error, :event_invalid}
    end
  end

  defp normalize_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(@list_limit_max)

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {n, _} -> normalize_limit(n)
      _ -> @list_limit_default
    end
  end

  defp normalize_limit(_), do: @list_limit_default

  defp required(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :event_invalid}
    end
  end
end
