defmodule MessageService.EventOutbox do
  @moduledoc """
  Durable intent for `message.events.v1` publishes — the C6 write-ahead pattern applied to Kafka
  (096). The fire-and-forget publish lost events silently (`{:ok, :produced}` is brod BUFFER-accept,
  not delivery), and a lost event never writes a consumer ledger row, so nothing ever retried.

  ## The row's life — a ONE-WAY state machine

    * `staged`    — inserted BEFORE the authoritative Scylla write: on the create path INSIDE the
      same Postgres transaction as the webhook intent (two observers of one event can never see
      different truth); on the delete path its own INSERT before the tombstone.
    * `pending`   — promoted after the Scylla write succeeded. The FAST PATH fires here: an
      unlinked Task attempts `produce_sync` immediately, so the happy path publishes without
      waiting for any sweep interval — the relay only ever ADDS attempts.
    * DELETED     — on broker-ACKED publish (`produce_sync`, not buffer-accept). A published row is
      transient intent with no read value; deleting it is what bounds the table.
    * `aborted`   — the Scylla write failed: kept with `last_error` as evidence. An aborted event
      is a message that never existed; publishing it would mint a phantom.

  A crash between stage and promote leaves `staged`; the relay resolves it against the
  AUTHORITATIVE store, exactly as the C6 sweeper does — created events promote when the message
  exists, deleted events promote when it is tombstoned, aborts carry evidence, and a store outage
  leaves the row for the next pass (absence must be proven by the store answering). Every window
  lands on DUPLICATED — absorbed by the five consumers' ledgers — never on LOST. Loss now requires
  losing Postgres durability itself.

  ## Scope: the SCYLLA adapter (the production store)

  Staging happens in `ScyllaAdapter.put_message`/`delete_message`. Other adapters (Postgres,
  dual-write — test/dev/rollback configurations) retain the legacy fire-and-forget publish in
  `Messages`, which skips itself when this outbox owns the event (`owns_publishes?/0`). Stated, not
  hidden: the durability upgrade covers the store production runs.

  ## Flags, both directions

  `KAFKA_PUBLISH_ENABLED=false` ⇒ `stage_*` return `[]` (no rows), the relay does no work — the
  dev no-publish mode is preserved. Flipped off MID-FLIGHT: already-pending rows SIT — the relay
  is gated, nothing aborts them, and they publish when the flag returns. That is deliberate: the
  events are real (their Scylla writes happened); dropping them would be the loss this module
  exists to end.
  """

  require Logger

  alias MessageService.MessageStore
  alias MessageService.Repo
  alias SharedInfra.Events.Envelope
  alias SharedInfra.Kafka.Producer

  @topic "message.events.v1"

  @doc "Does the outbox own publishing for the selected store adapter (+ flag)?"
  def owns_publishes? do
    publish_enabled?() and
      Application.get_env(:message_service, :message_store_adapter) ==
        MessageService.MessageStore.ScyllaAdapter
  end

  @doc """
  Stage a message.created event. MUST run inside the caller's Postgres transaction (the webhook
  stage transaction — the joined-transaction decision). Returns staged row ids ([] when publishing
  is disabled).
  """
  def stage_created(attrs) do
    stage("message.created.v1", attrs, %{
      "conversation_id" => attr(attrs, "conversation_id"),
      "message_id" => attr(attrs, "message_id"),
      "sender_user_id" => attr(attrs, "sender_user_id")
    })
  end

  @doc "Stage a message.deleted event (before the tombstone). Returns staged row ids."
  def stage_deleted(attrs) do
    stage("message.deleted.v1", attrs, %{
      "conversation_id" => attr(attrs, "conversation_id"),
      "message_id" => attr(attrs, "message_id"),
      "sender_user_id" => attr(attrs, "sender_user_id"),
      "deleted_at" => attr(attrs, "deleted_at") || DateTime.utc_now()
    })
  end

  defp stage(event_type, _attrs, payload) do
    if publish_enabled?() do
      envelope_attrs = %{
        event_id: Ecto.UUID.generate(),
        event_type: event_type,
        event_version: 1,
        producer: "message-service",
        occurred_at: DateTime.utc_now(),
        correlation_id: SharedInfra.Correlation.get_or_generate(),
        actor_user_id: payload["sender_user_id"],
        payload: payload
      }

      case Envelope.build(envelope_attrs) do
        {:ok, envelope} ->
          %{rows: [[id]]} =
            Repo.query!(
              "INSERT INTO kafka_event_outbox " <>
                "(topic, partition_key, event_type, envelope, conversation_id, message_id) " <>
                "VALUES ($1, $2, $3, $4, $5::text::uuid, $6::text::uuid) RETURNING id::text",
              [
                @topic,
                payload["conversation_id"],
                event_type,
                envelope,
                payload["conversation_id"],
                payload["message_id"]
              ]
            )

          [id]

        {:error, reason} ->
          # Structural: an envelope that cannot build cannot be staged. Loud — this is a code
          # defect, not a transient.
          Logger.error(
            "event outbox: #{event_type} envelope invalid, NOT staged: #{inspect(reason)}"
          )

          []
      end
    else
      []
    end
  end

  @doc "Promote staged rows to pending (the Scylla write succeeded) and fire the fast path."
  def promote_and_publish_async([]), do: :ok

  def promote_and_publish_async(ids) do
    Repo.query!(
      "UPDATE kafka_event_outbox SET status = 'pending' " <>
        "WHERE id = ANY($1::text[]::uuid[]) AND status = 'staged'",
      [ids]
    )

    # THE FAST PATH (trap 4): attempt immediately, off the request path. The relay is the backstop,
    # not the primary — the happy path never waits for a sweep interval.
    Task.start(fn -> Enum.each(ids, &publish_pending/1) end)
    :ok
  end

  @doc "Abort staged rows (the Scylla write failed) — kept as evidence, never published."
  def abort([], _reason), do: :ok

  def abort(ids, reason) do
    Repo.query!(
      "UPDATE kafka_event_outbox SET status = 'aborted', last_error = $2 " <>
        "WHERE id = ANY($1::text[]::uuid[]) AND status IN ('staged', 'pending')",
      [ids, String.slice(to_string(reason), 0, 500)]
    )

    :ok
  end

  @doc """
  Publish ONE pending row by id: broker-acked produce_sync, then DELETE the row. Failure records
  the attempt and leaves the row pending for the relay. Publishing an already-deleted row is a
  no-op (a racing relay pass and fast path converge here).
  """
  def publish_pending(id) do
    case Repo.query!(
           "SELECT topic, partition_key, envelope FROM kafka_event_outbox " <>
             "WHERE id = $1::text::uuid AND status = 'pending'",
           [id]
         ) do
      %{rows: [[topic, key, envelope]]} ->
        case Producer.produce_sync(topic, key, envelope) do
          :ok ->
            Repo.query!("DELETE FROM kafka_event_outbox WHERE id = $1::text::uuid", [id])
            :published

          {:error, reason} ->
            Repo.query!(
              "UPDATE kafka_event_outbox SET attempts = attempts + 1, last_error = $2 " <>
                "WHERE id = $1::text::uuid",
              [id, String.slice(inspect(reason), 0, 500)]
            )

            Logger.warning(
              "event outbox: publish failed (relay will retry) id=#{id}: #{inspect(reason)}"
            )

            :failed
        end

      %{rows: []} ->
        :gone
    end
  end

  @doc """
  One relay pass: publish pending rows (oldest first, bounded batch), then resolve stale STAGED
  rows against the authoritative store — the C6 sweeper contract. Returns counts. Gated on the
  publish flag: flag off ⇒ %{skipped: true} and NOTHING moves (mid-flight rows sit; see moduledoc).
  """
  def relay_pass(stale_seconds \\ 60, batch \\ 100) do
    if publish_enabled?() do
      pending = publish_batch(batch)
      staged = resolve_stale_staged(stale_seconds, batch)
      Map.merge(pending, staged)
    else
      %{skipped: true}
    end
  end

  defp publish_batch(batch) do
    %{rows: rows} =
      Repo.query!(
        "SELECT id::text FROM kafka_event_outbox WHERE status = 'pending' " <>
          "ORDER BY created_at LIMIT $1",
        [batch]
      )

    Enum.reduce(rows, %{published: 0, failed: 0}, fn [id], acc ->
      case publish_pending(id) do
        :published -> %{acc | published: acc.published + 1}
        _ -> %{acc | failed: acc.failed + 1}
      end
    end)
  end

  # Stale staged rows: the crash window between stage and promote. Resolve against the STORE —
  # absence must be proven by the store answering, never inferred from it not answering.
  defp resolve_stale_staged(stale_seconds, batch) do
    %{rows: rows} =
      Repo.query!(
        "SELECT id::text, event_type, conversation_id::text, message_id::text " <>
          "FROM kafka_event_outbox WHERE status = 'staged' " <>
          "AND created_at < now() - make_interval(secs => $1) " <>
          "ORDER BY created_at LIMIT $2",
        [stale_seconds, batch]
      )

    Enum.reduce(rows, %{promoted: 0, aborted: 0, left: 0}, fn
      [id, event_type, conversation_id, message_id], acc ->
        case store_verdict(event_type, conversation_id, message_id) do
          :promote ->
            Repo.query!(
              "UPDATE kafka_event_outbox SET status = 'pending' " <>
                "WHERE id = $1::text::uuid AND status = 'staged'",
              [id]
            )

            publish_pending(id)
            %{acc | promoted: acc.promoted + 1}

          :abort ->
            abort([id], "relay: store contradicts staged #{event_type}")
            %{acc | aborted: acc.aborted + 1}

          :leave ->
            %{acc | left: acc.left + 1}
        end
    end)
  end

  # created: the message existing (even tombstoned — consumers handle tombstones) proves the write
  # landed. deleted: only a TOMBSTONE proves it; a live message means the delete never happened and
  # publishing would mint a phantom delete.
  defp store_verdict(event_type, conversation_id, message_id) do
    case MessageStore.get_message(%{
           "conversation_id" => conversation_id,
           "message_id" => message_id
         }) do
      {:ok, message} ->
        deleted = get(message, :status) == "deleted" or not is_nil(get(message, :deleted_at))

        case event_type do
          "message.created.v1" -> :promote
          "message.deleted.v1" -> if deleted, do: :promote, else: :abort
          _ -> :abort
        end

      {:error, :message_not_found} ->
        :abort

      _ ->
        :leave
    end
  end

  defp publish_enabled? do
    Application.get_env(:message_service, :kafka_publish_enabled, false) ||
      System.get_env("KAFKA_PUBLISH_ENABLED") in ["true", "1", "yes"]
  end

  defp attr(map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))
  defp get(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end
