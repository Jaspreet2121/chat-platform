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

  # Retry policy (Phase 3 wires backoff; the dead-letter cap is the start of Phase 4).
  @max_attempts 6
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
          "          payload, attempts, created_at::text",
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
