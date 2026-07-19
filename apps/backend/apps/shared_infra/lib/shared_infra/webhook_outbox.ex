defmodule SharedInfra.WebhookOutbox do
  @moduledoc """
  Transactional webhook outbox — the single home for emit + delivery, parameterized by Ecto Repo
  (raw SQL, so no per-service schema duplication; every service Repo points at the same DB).

    * `emit/4` — called by the domain services INSIDE their write transaction (message_service's
      put_message, conversation_service's create): inserts one `webhook_outbox` row per enabled
      endpoint subscribed to the event, scoped to the write's authoritative app_id. Atomic with the
      domain row — a rollback drops the outbox rows too; a commit guarantees them.
    * `claim_due/2` + `deliver/2` — called by the delivery worker (auth_service): claims due rows
      with FOR UPDATE SKIP LOCKED (multi-replica safe), signs the exact body with HMAC-SHA256, POSTs
      to the endpoint, and marks delivered / schedules a backoff retry. Only ever delivers a row to an
      endpoint of the SAME app_id (tenant isolation).
  """

  require Logger

  # Retry policy (Phase 3 wires backoff; the dead-letter cap is the start of Phase 4).
  @max_attempts 6
  # Phase 4: ceiling on a single bulk re-drive so one call can't scan/lock the whole table.
  @max_bulk 500
  @base_backoff_seconds 5
  @cap_backoff_seconds 300
  # Visibility timeout: a claimed ('delivering') row becomes due again after this, so a worker that
  # dies mid-delivery doesn't strand the event (it's reclaimed on the next poll).
  @visibility_seconds 60
  @http_timeout_ms 5_000

  @doc """
  Insert one outbox row per enabled endpoint subscribed to `event_type` for `app_id`. MUST run inside
  the caller's `repo.transaction/1` so it commits atomically with the domain write. No-op if app_id is
  blank or no endpoint subscribes.
  """
  def emit(repo, app_id, event_type, payload)
      when is_binary(app_id) and app_id != "" and is_binary(event_type) do
    payload_json = Jason.encode!(payload)

    {:ok, %{rows: endpoints}} =
      repo.query(
        "SELECT id::text FROM webhook_endpoints " <>
          "WHERE app_id = $1::text::uuid AND enabled = true AND $2 = ANY(event_types)",
        [app_id, event_type]
      )

    Enum.each(endpoints, fn [endpoint_id] ->
      repo.query!(
        "INSERT INTO webhook_outbox " <>
          "(id, app_id, endpoint_id, event_id, event_type, payload, status, attempts, next_attempt_at, created_at) " <>
          "VALUES (gen_random_uuid(), $1::text::uuid, $2::text::uuid, gen_random_uuid(), $3, $4::jsonb, 'pending', 0, now(), now())",
        [app_id, endpoint_id, event_type, payload_json]
      )
    end)

    :ok
  end

  def emit(_repo, _app_id, _event_type, _payload), do: :ok

  @doc """
  Atomically claim up to `limit` due rows (pending OR a stale 'delivering') with FOR UPDATE SKIP LOCKED,
  mark them 'delivering' (hide for the visibility window), and return them. Concurrent workers never
  claim the same row.
  """
  def claim_due(repo, limit) do
    {:ok, %{rows: rows}} =
      repo.query(
        "UPDATE webhook_outbox SET status = 'delivering', next_attempt_at = now() + make_interval(secs => $2) " <>
          "WHERE id IN ( " <>
          "  SELECT id FROM webhook_outbox " <>
          "  WHERE status IN ('pending','delivering') AND next_attempt_at <= now() " <>
          "  ORDER BY next_attempt_at LIMIT $1 FOR UPDATE SKIP LOCKED ) " <>
          "RETURNING id::text, app_id::text, endpoint_id::text, event_id::text, event_type, " <>
          "          payload, attempts, " <>
          "to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')",
        [limit, @visibility_seconds]
      )

    Enum.map(rows, fn [id, app_id, endpoint_id, event_id, event_type, payload, attempts, created_at] ->
      %{
        id: id,
        app_id: app_id,
        endpoint_id: endpoint_id,
        event_id: event_id,
        event_type: event_type,
        payload: payload,
        attempts: attempts,
        created_at: created_at
      }
    end)
  end

  @doc "Deliver one claimed row to its endpoint (same app_id only), then mark delivered or schedule retry."
  def deliver(repo, row) do
    case endpoint(repo, row.endpoint_id, row.app_id) do
      {:ok, url, signing_secret} ->
        body = build_body(row)
        signature = "sha256=" <> hmac_hex(signing_secret, body)
        timestamp = DateTime.utc_now() |> DateTime.to_unix() |> Integer.to_string()

        headers = [
          {"content-type", "application/json"},
          {"x-webhook-signature", signature},
          {"x-webhook-id", row.id},
          {"x-webhook-event-id", row.event_id},
          {"x-webhook-event-type", row.event_type},
          {"x-webhook-timestamp", timestamp}
        ]

        case post(url, body, headers) do
          {:ok, status} when status in 200..299 -> mark_delivered(repo, row.id)
          {:ok, status} -> mark_retry(repo, row, "HTTP #{status}")
          {:error, reason} -> mark_retry(repo, row, "transport: #{inspect(reason)}")
        end

      :no_endpoint ->
        # Endpoint disabled/deleted since emit — drop the row (terminal, not an error).
        mark_delivered(repo, row.id)
    end
  rescue
    error -> mark_retry(repo, row, "exception: #{Exception.message(error)}")
  end

  # --- Phase 4: failed-delivery ops ------------------------------------------------------------

  @doc """
  Keyset-paginated list of FAILED (dead-lettered) deliveries. opts: :app_id, :event_type,
  :limit (<=200), :cursor {created_at_iso, id}. Returns %{items, next_cursor: %{...}|nil, count}.
  Keyset (created_at,id) — no OFFSET, so it stays fast as the dead-letter set grows.
  """
  def list_failed(repo, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 50) |> min(200) |> max(1)
    {where, params, n} = {["o.status = 'failed'"], [], 0}

    {where, params, n} =
      case Keyword.get(opts, :app_id) do
        v when is_binary(v) and v != "" ->
          {where ++ ["o.app_id = $#{n + 1}::text::uuid"], params ++ [v], n + 1}

        _ ->
          {where, params, n}
      end

    {where, params, n} =
      case Keyword.get(opts, :event_type) do
        v when is_binary(v) and v != "" ->
          {where ++ ["o.event_type = $#{n + 1}"], params ++ [v], n + 1}

        _ ->
          {where, params, n}
      end

    {where, params, n} =
      case Keyword.get(opts, :cursor) do
        {ts, id} when is_binary(ts) and is_binary(id) ->
          {where ++ ["(o.created_at, o.id) < ($#{n + 1}::text::timestamptz, $#{n + 2}::text::uuid)"],
           params ++ [ts, id], n + 2}

        _ ->
          {where, params, n}
      end

    sql =
      "SELECT o.id::text, o.event_id::text, o.event_type, o.app_id::text, e.url AS endpoint_url, " <>
        "o.attempts, o.last_error, o.next_attempt_at::text, o.created_at::text " <>
        "FROM webhook_outbox o LEFT JOIN webhook_endpoints e ON e.id = o.endpoint_id " <>
        "WHERE #{Enum.join(where, " AND ")} ORDER BY o.created_at DESC, o.id DESC LIMIT $#{n + 1}"

    %{rows: rows, columns: cols} = repo.query!(sql, params ++ [limit])
    items = Enum.map(rows, fn r -> cols |> Enum.zip(r) |> Map.new() end)

    next_cursor =
      if length(items) == limit and items != [] do
        last = List.last(items)
        %{"created_at" => last["created_at"], "id" => last["id"]}
      else
        nil
      end

    %{items: items, next_cursor: next_cursor, count: length(items)}
  end

  @doc """
  OWNER-FACING delivery log for ONE app — every status (not just failed), keyset-paginated exactly like
  `list_failed/2` (`ORDER BY created_at DESC, id DESC`, cursor `{created_at_iso, id}`).

  `:app_id` is MANDATORY and is the tenant boundary: without it this returns an EMPTY page rather than
  running an unscoped query, so an owner console can never accidentally read another app's deliveries.
  opts: :app_id (required), :status, :endpoint_id, :limit (<=100), :cursor {created_at_iso, id}.

  NEVER selects `payload` — the outbox payload carries the event body (a message.created payload contains
  MESSAGE CONTENT), and this is a metadata log. `signing_secret` is likewise never joined in.
  """
  def list_deliveries(repo, opts \\ []) do
    case Keyword.get(opts, :app_id) do
      app_id when is_binary(app_id) and app_id != "" -> do_list_deliveries(repo, app_id, opts)
      # No app scope → refuse to query. An unscoped delivery list is a cross-tenant leak by construction.
      _ -> %{items: [], next_cursor: nil, count: 0}
    end
  end

  defp do_list_deliveries(repo, app_id, opts) do
    limit = opts |> Keyword.get(:limit, 30) |> min(100) |> max(1)
    {where, params, n} = {["o.app_id = $1::text::uuid"], [app_id], 1}

    {where, params, n} =
      case Keyword.get(opts, :status) do
        v when v in ["pending", "delivering", "delivered", "failed"] ->
          {where ++ ["o.status = $#{n + 1}"], params ++ [v], n + 1}

        _ ->
          {where, params, n}
      end

    {where, params, n} =
      case Keyword.get(opts, :endpoint_id) do
        v when is_binary(v) and v != "" ->
          {where ++ ["o.endpoint_id = $#{n + 1}::text::uuid"], params ++ [v], n + 1}

        _ ->
          {where, params, n}
      end

    {where, params, n} =
      case Keyword.get(opts, :cursor) do
        {ts, id} when is_binary(ts) and is_binary(id) ->
          {where ++ ["(o.created_at, o.id) < ($#{n + 1}::text::timestamptz, $#{n + 2}::text::uuid)"],
           params ++ [ts, id], n + 2}

        _ ->
          {where, params, n}
      end

    sql =
      "SELECT o.id::text, o.event_id::text, o.event_type, o.status, o.attempts, o.last_error, " <>
        "o.endpoint_id::text, e.url AS endpoint_url, o.created_at::text, o.delivered_at::text, " <>
        "o.next_attempt_at::text " <>
        "FROM webhook_outbox o LEFT JOIN webhook_endpoints e ON e.id = o.endpoint_id " <>
        "WHERE #{Enum.join(where, " AND ")} ORDER BY o.created_at DESC, o.id DESC LIMIT $#{n + 1}"

    %{rows: rows, columns: cols} = repo.query!(sql, params ++ [limit])
    items = Enum.map(rows, fn r -> cols |> Enum.zip(r) |> Map.new() end)

    next_cursor =
      if length(items) == limit and items != [] do
        last = List.last(items)
        %{"created_at" => last["created_at"], "id" => last["id"]}
      else
        nil
      end

    %{items: items, next_cursor: next_cursor, count: length(items)}
  end

  @doc """
  Reset ONE failed row → pending (attempts=0, REUSING event_id so an integrator's dedupe on
  x-webhook-event-id still holds), locked FOR UPDATE SKIP LOCKED. Idempotent: a non-failed / locked /
  missing row is a no-op. Returns {:ok, :reenqueued} | {:ok, :noop, reason} | {:error, term}.
  """
  def reenqueue(repo, outbox_id, opts \\ []) do
    actor = Keyword.get(opts, :actor, "system")

    repo.transaction(fn ->
      lock =
        repo.query!(
          "SELECT id::text, event_id::text, status FROM webhook_outbox " <>
            "WHERE id = $1::text::uuid FOR UPDATE SKIP LOCKED",
          [outbox_id]
        )

      case lock.rows do
        [] ->
          repo.rollback(:locked_or_missing)

        [[id, event_id, "failed"]] ->
          repo.query!(
            "UPDATE webhook_outbox SET status='pending', attempts=0, last_error=NULL, " <>
              "next_attempt_at=now() WHERE id=$1::text::uuid",
            [outbox_id]
          )

          audit!(repo, id, event_id, "reenqueue", actor, "failed", "pending")
          Logger.info("[webhook_outbox] reenqueue id=#{id} event_id=#{event_id} actor=#{actor}")
          :reenqueued

        [[_id, _event_id, other]] ->
          repo.rollback({:not_failed, other})
      end
    end)
    |> normalize_reenqueue()
  end

  defp normalize_reenqueue({:ok, :reenqueued}), do: {:ok, :reenqueued}
  defp normalize_reenqueue({:error, :locked_or_missing}), do: {:ok, :noop, :locked_or_missing}
  defp normalize_reenqueue({:error, {:not_failed, status}}), do: {:ok, :noop, {:not_failed, status}}
  defp normalize_reenqueue(other), do: other

  @doc "Bulk re-drive up to :limit (<= #{@max_bulk}) failed rows for a filter. Returns {:ok, count}."
  def reenqueue_bulk(repo, filter, opts \\ []) do
    actor = Keyword.get(opts, :actor, "system")
    limit = filter |> Keyword.get(:limit, 100) |> min(@max_bulk) |> max(1)

    repo.transaction(fn ->
      {conds, params, n} = {["status = 'failed'"], [], 0}

      {conds, params, n} =
        case Keyword.get(filter, :app_id) do
          v when is_binary(v) and v != "" ->
            {conds ++ ["app_id = $#{n + 1}::text::uuid"], params ++ [v], n + 1}

          _ ->
            {conds, params, n}
        end

      {conds, params, n} =
        case Keyword.get(filter, :event_type) do
          v when is_binary(v) and v != "" ->
            {conds ++ ["event_type = $#{n + 1}"], params ++ [v], n + 1}

          _ ->
            {conds, params, n}
        end

      sql =
        "WITH picked AS (SELECT id FROM webhook_outbox WHERE #{Enum.join(conds, " AND ")} " <>
          "ORDER BY created_at ASC LIMIT $#{n + 1} FOR UPDATE SKIP LOCKED) " <>
          "UPDATE webhook_outbox o SET status='pending', attempts=0, last_error=NULL, next_attempt_at=now() " <>
          "FROM picked WHERE o.id = picked.id RETURNING o.id::text, o.event_id::text"

      %{rows: rows} = repo.query!(sql, params ++ [limit])

      Enum.each(rows, fn [id, eid] ->
        audit!(repo, id, eid, "reenqueue_bulk", actor, "failed", "pending")
      end)

      Logger.info("[webhook_outbox] reenqueue_bulk count=#{length(rows)} actor=#{actor}")
      length(rows)
    end)
  end

  defp audit!(repo, outbox_id, event_id, action, actor, from_status, to_status) do
    repo.query!(
      "INSERT INTO webhook_outbox_audit (outbox_id, event_id, action, actor, from_status, to_status) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, $4, $5, $6)",
      [outbox_id, event_id, action, actor, from_status, to_status]
    )
  end

  # --- internals -------------------------------------------------------------------------------

  defp endpoint(repo, endpoint_id, app_id) do
    case repo.query(
           "SELECT url, signing_secret FROM webhook_endpoints " <>
             "WHERE id = $1::text::uuid AND app_id = $2::text::uuid AND enabled = true",
           [endpoint_id, app_id]
         ) do
      {:ok, %{rows: [[url, signing_secret]]}} -> {:ok, url, signing_secret}
      _ -> :no_endpoint
    end
  end

  # The signed envelope — the EXACT bytes POSTed (so the integrator HMACs the same raw body).
  defp build_body(row) do
    Jason.encode!(%{
      "id" => row.event_id,
      "type" => row.event_type,
      "created_at" => row.created_at,
      "data" => decode_payload(row.payload)
    })
  end

  defp decode_payload(payload) when is_map(payload), do: payload
  defp decode_payload(payload) when is_binary(payload), do: Jason.decode!(payload)
  defp decode_payload(_), do: %{}

  defp hmac_hex(secret, body),
    do: :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)

  defp post(url, body, headers) do
    case Req.post(url,
           body: body,
           headers: headers,
           receive_timeout: @http_timeout_ms,
           retry: false,
           decode_body: false
         ) do
      {:ok, %Req.Response{status: status}} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_delivered(repo, id) do
    repo.query!(
      "UPDATE webhook_outbox SET status='delivered', delivered_at=now(), last_error=NULL WHERE id=$1::text::uuid",
      [id]
    )

    :ok
  end

  defp mark_retry(repo, row, error) do
    attempts = (row.attempts || 0) + 1

    if attempts >= @max_attempts do
      # Dead-letter: keep last_error for inspection (Phase 4 adds the list/re-enqueue surface).
      repo.query!(
        "UPDATE webhook_outbox SET status='failed', attempts=$2, last_error=$3 WHERE id=$1::text::uuid",
        [row.id, attempts, error]
      )
    else
      backoff = min(@cap_backoff_seconds, trunc(@base_backoff_seconds * :math.pow(2, attempts - 1)))

      repo.query!(
        "UPDATE webhook_outbox SET status='pending', attempts=$2, " <>
          "next_attempt_at=now() + make_interval(secs => $3), last_error=$4 WHERE id=$1::text::uuid",
        [row.id, attempts, backoff, error]
      )
    end

    :ok
  end
end
