defmodule MessageService.ViewOnceLedger do
  @moduledoc """
  The view-once expiry ledger (127) — the rows the 14-day sweep actually reads.

  ## Why it exists

  `ViewOnce.expired_unopened_media/0` selected `FROM messages`, which is EMPTY under
  `MESSAGE_STORE_ADAPTER=scylla`. Production on 2026-09-20: `messages` 0 rows, `view_once` 0 rows,
  `view_once_opens` **10 rows** — the feature is in daily use and the sweep had never seen one
  candidate. Every unopened view-once blob ever sent is still in MinIO.

  A store-correct query cannot replace it: the sweep asks for "every unopened view-once message older
  than 14 days", a RANGE across conversations, and Scylla answers point reads and partition walks.
  This table is that question's shape, in the store where `view_once_opens` already lives.

  ## The three invariants

    * **Written BEFORE the Scylla put**, inside the transaction that already stages the outbox. A
      crash between the two leaves a row with no blob — a purge that finds nothing, stamps, and
      moves on. The reverse, a blob with no row, would be unreclaimable, and this ordering makes it
      unreachable.
    * **Deleted in the SAME transaction that records the open.** An opened message can never be
      swept, because the row and the open cannot disagree.
    * **`purged_at` stamped only AFTER a successful purge.** Stamping first is exactly how the status
      sweep leaked 22 blobs in September (`MessageService.Statuses.run_sweep/0`); an unstamped row is
      retried forever.

  ## No backfill

  View-once messages sent before 127 have no row and can never be swept. Reconstructing them would
  mean scanning every conversation partition in Scylla for a boolean. Recorded in the contract;
  going forward is enough.
  """

  require Logger

  alias MessageService.Repo

  @sweep_batch 50

  @doc "The sweep's batch size."
  def sweep_batch, do: @sweep_batch

  @doc """
  Record a view-once send. Runs INSIDE the caller's transaction — it takes no transaction of its own,
  because its whole value is committing or rolling back with the outbox staging beside it.

  Idempotent on `message_id`: an idempotent resend (107 replays a `client_msg_id`) must not raise.
  Returns `:ok`; a non-view-once message, or one with no media, writes nothing.
  """
  def record(attrs, expiry_days) when is_integer(expiry_days) and expiry_days > 0 do
    with true <- attr(attrs, "view_once") == true,
         message_id when is_binary(message_id) <- attr(attrs, "message_id"),
         media_id when is_binary(media_id) and media_id != "" <- attr(attrs, "media_id"),
         conversation_id when is_binary(conversation_id) <- attr(attrs, "conversation_id"),
         sender_user_id when is_binary(sender_user_id) <- attr(attrs, "sender_user_id") do
      expires_at =
        (attr(attrs, "created_at") || DateTime.utc_now())
        |> to_datetime()
        |> DateTime.add(expiry_days * 86_400, :second)

      Repo.query!(
        "INSERT INTO view_once_expiry " <>
          "(message_id, conversation_id, media_id, sender_user_id, app_id, expires_at) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, $4::text::uuid, " <>
          "        COALESCE($5::text::uuid, '00000000-0000-0000-0000-000000000001'::uuid), $6) " <>
          "ON CONFLICT (message_id) DO NOTHING",
        [
          message_id,
          conversation_id,
          media_id,
          sender_user_id,
          app_id(attrs),
          expires_at
        ]
      )

      :ok
    else
      _ -> :ok
    end
  end

  @doc """
  Forget a message's ledger row — called from inside the open transaction. Deleting rather than
  stamping is deliberate: the row means "a purge is still owed", and after an open it is not.
  """
  def forget(message_id) when is_binary(message_id) and message_id != "" do
    Repo.query!("DELETE FROM view_once_expiry WHERE message_id = $1::text::uuid", [message_id])
    :ok
  rescue
    error ->
      # The open itself has already been recorded; a failed delete leaves a row the sweep would
      # purge, so this is loud rather than silent.
      Logger.error(
        "view_once ledger delete FAILED for message=#{message_id} — an OPENED message may be " <>
          "swept: #{inspect(error)}"
      )

      :ok
  end

  @doc """
  Candidates for the sweep: unpurged rows past their deadline, oldest first, at most `sweep_batch`.
  Reads the LEDGER — never `messages`, which is the whole point of 127.
  """
  def due(now \\ DateTime.utc_now()) do
    %{rows: rows} =
      Repo.query!(
        "SELECT message_id::text, media_id::text, sender_user_id::text, app_id::text " <>
          "FROM view_once_expiry " <>
          "WHERE purged_at IS NULL AND expires_at < $1 " <>
          "ORDER BY expires_at LIMIT #{@sweep_batch}",
        [now]
      )

    Enum.map(rows, fn [message_id, media_id, sender_user_id, app_id] ->
      %{
        message_id: message_id,
        media_id: media_id,
        sender_user_id: sender_user_id,
        app_id: app_id
      }
    end)
  end

  @doc """
  Stamp a row as purged. Called ONLY after the media service has confirmed the blob is gone — see
  the moduledoc; the status sweep's leak is the reason this is a separate call rather than part of
  the same statement that selected the row.
  """
  def mark_purged(message_id) when is_binary(message_id) do
    Repo.query!(
      "UPDATE view_once_expiry SET purged_at = now() WHERE message_id = $1::text::uuid",
      [message_id]
    )

    :ok
  end

  defp app_id(attrs) do
    case attr(attrs, "app_id") do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp to_datetime(%DateTime{} = value), do: value
  defp to_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")

  defp to_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> parsed
      _ -> DateTime.utc_now()
    end
  end

  defp to_datetime(_value), do: DateTime.utc_now()

  defp attr(attrs, key) when is_map(attrs), do: SharedInfra.Attrs.get(attrs, String.to_atom(key))
  defp attr(_attrs, _key), do: nil
end
