defmodule MessageService.ViewOnce do
  @moduledoc """
  View-once sends (115): the per-recipient open ledger, the download gate's state machine, and the
  lazy purge.

  WHY THIS LIVES IN message_service: the authorization question is about a MESSAGE ("is there a
  view-once message referencing this media_id, and has this viewer opened it"), and messages plus
  `view_once_opens` are in the same Repo as the existing `media_download_allowed` oracle. The gateway
  asks; it does not own the answer.

  THE HONEST LIMITS, so nobody reads more into this than it delivers: view-once controls SERVER
  ACCESS to the blob. It cannot stop a screenshot, a screen recording, or another phone pointed at
  the screen. For secret chats the server never sees the media_id at all (it rides inside the
  ciphertext), so view-once there is client-enforced and is refused at create rather than accepted
  and silently unenforceable.
  """

  require Logger

  alias MessageService.MessageStore
  alias MessageService.Repo

  # Unopened view-once media stops being readable after this, whether or not anyone ever asked for
  # it. Lazy: there is no cron in this system, so expiry is evaluated on the paths that already
  # touch these rows (the download gate and the open endpoint).
  @expiry_days 14

  # Bounded so an opportunistic sweep on a user-facing request can never become a long query.
  @sweep_batch 50

  @doc "The expiry window, in days. Public so the contract can be asserted rather than duplicated."
  def expiry_days, do: @expiry_days

  @doc """
  The download gate's state for (media_id, viewer).

  FIVE OUTCOMES, and the first one is the one that matters most:

    * `:not_view_once` — no view-once message references this media. **Also returned when the probe
      itself fails.** A broken or unavailable probe must never deny ordinary media: this gate is an
      additional restriction on a narrow feature, not a new dependency for every download in the
      system. Failing closed here would turn a database hiccup into a total media outage.
    * `:sender` — the viewer sent it. Denied: view-once is one-way, and a sender who could re-read
      their own send would keep a copy of what the recipient believes is gone.
    * `:opened` — the viewer already opened it. Denied.
    * `:expired` — nobody opened it within the window. Denied.
    * `:unopened` — the viewer may read it exactly once more.
  """
  def state(media_id, viewer_id) do
    case fetch_view_once(media_id) do
      nil ->
        :not_view_once

      %{sender_user_id: ^viewer_id} ->
        :sender

      %{message_id: message_id, created_at: created_at} ->
        cond do
          opened?(message_id, viewer_id) -> :opened
          expired?(created_at) -> :expired
          true -> :unopened
        end
    end
  rescue
    error ->
      # LOUD, but still permissive. Same reasoning as media_download_allowed's rescue: an exception
      # means the gate is broken, not that the answer is "deny" — and denying here would break
      # ordinary media for everyone.
      Logger.error(
        "view_once state probe FAILED (treating as not-view-once, this is a FAULT not a decision): " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :not_view_once
  end

  @doc """
  Record an open. WRITE-ONCE: the first open wins and a replay returns the ORIGINAL `opened_at`, so a
  client retrying a lost response cannot move the timestamp or re-trigger the purge.

  Returns `{:ok, %{opened_at, media_id, sender_user_id, first_open?}}`. `sender_user_id` is the
  MESSAGE's sender: the purge that follows a first open is scoped to that owner, and it must never be
  the opener (see MediaService.Media.purge_asset/1). `first_open?` tells the caller whether this
  request is the one that should purge the blob.
  """
  def open(conversation_id, message_id, viewer_id) do
    case fetch_message(conversation_id, message_id) do
      nil ->
        {:error, :not_found}

      %{view_once: false} ->
        {:error, :not_found}

      %{sender_user_id: ^viewer_id} ->
        {:error, :sender_cannot_open}

      %{conversation_id: resolved_conversation_id, media_id: media_id, sender_user_id: sender} ->
        # ONE TRANSACTION for the open AND the ledger delete (127). They cannot disagree: if the
        # open is recorded, the expiry row is gone, so an opened message can never be swept — and if
        # anything here rolls back, neither happened.
        {:ok, rows} =
          Repo.transaction(fn ->
            %{rows: rows} =
              Repo.query!(
                """
                INSERT INTO view_once_opens (message_id, user_id, conversation_id, opened_at)
                VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, now())
                ON CONFLICT (message_id, user_id) DO NOTHING
                RETURNING opened_at
                """,
                [message_id, viewer_id, resolved_conversation_id]
              )

            MessageService.ViewOnceLedger.forget(message_id)
            rows
          end)

        case rows do
          # Inserted: this request is the first open.
          [[opened_at]] ->
            {:ok,
             %{
               opened_at: opened_at,
               media_id: media_id,
               sender_user_id: sender,
               first_open?: true
             }}

          # DO NOTHING returns no row — read the original back. Idempotent by contract: same body,
          # same timestamp, no second purge.
          [] ->
            {:ok,
             %{
               opened_at: existing_opened_at(message_id, viewer_id),
               media_id: media_id,
               sender_user_id: sender,
               first_open?: false
             }}
        end
    end
  end

  @doc """
  THE EXPIRY SWEEP: purge the blobs of view-once messages whose window passed with nobody opening
  them.

  Reads the LEDGER (`view_once_expiry`, migration 127) — never `messages`, which is empty under the
  Scylla store and is why this sweep had never seen a candidate in production despite the feature
  being in daily use (10 real opens, 0 candidates, ever). Batched at #{@sweep_batch}.

  Each purge is OWNER-SCOPED with the row's own `sender_user_id`: `purge_asset` refuses a purge
  whose expected owner does not match, and the old payload carried bare media ids, so even a
  working query could not have deleted anything.

  `purged_at` is stamped ONLY after the media service confirms the blob is gone. A failed purge
  leaves the row unstamped and it is retried on the next sweep — the discipline the status sweep had
  to learn after stamping-before-purging leaked 22 blobs.

  `dry_run: true` reports exactly what it WOULD purge and touches nothing: no delete, no stamp.
  That is how this runs the first time in production.

  → `%{candidates: k, purged: n, failed: m, dry_run: bool}`, and ALWAYS logs — including a zero-row
  run, because "the sweep ran and found nothing" and "the sweep never ran" are the two states this
  whole slice exists to tell apart.
  """
  def sweep(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    candidates = MessageService.ViewOnceLedger.due()

    {purged, failed} =
      if dry_run? do
        {0, 0}
      else
        Enum.reduce(candidates, {0, 0}, fn row, {ok, bad} ->
          case purge(row) do
            :ok ->
              MessageService.ViewOnceLedger.mark_purged(row.message_id)
              {ok + 1, bad}

            :error ->
              {ok, bad + 1}
          end
        end)
      end

    Logger.info(
      "view_once sweep purged=#{purged} failed=#{failed} candidates=#{length(candidates)}" <>
        if(dry_run?, do: " dry_run=true", else: "")
    )

    %{candidates: length(candidates), purged: purged, failed: failed, dry_run: dry_run?}
  rescue
    error ->
      Logger.warning(
        "view_once sweep failed (non-fatal): " <> Exception.format(:error, error, [])
      )

      %{candidates: 0, purged: 0, failed: 0, dry_run: Keyword.get(opts, :dry_run, false)}
  end

  # The owner-scoped delete. A MISSING asset answers {:ok, purged: false}, which IS success here: a
  # crash between the ledger write and the Scylla put leaves a row whose blob never existed, and
  # that row must stamp rather than be retried forever.
  defp purge(row) do
    case SharedInfra.MediaClient.purge_asset(%{
           "media_id" => row.media_id,
           "app_id" => row.app_id,
           "expected_owner_user_id" => row.sender_user_id
         }) do
      {:ok, _} ->
        :ok

      other ->
        Logger.warning(
          "view_once purge failed message=#{row.message_id} media=#{row.media_id}: " <>
            "#{inspect(other)}"
        )

        :error
    end
  rescue
    error ->
      Logger.warning("view_once purge raised message=#{row.message_id}: #{inspect(error)}")
      :error
  end

  @doc """
  Media ids the sweep would act on. Kept for the internal-API contract and now reading the LEDGER,
  so a caller that still asks this question gets a store-correct answer rather than the empty list
  the `messages` query always returned.
  """
  def expired_unopened_media do
    MessageService.ViewOnceLedger.due() |> Enum.map(& &1.media_id)
  end

  # THROUGH THE CONFIGURED ADAPTER, never a hardcoded Postgres SELECT.
  #
  # These two lookups read `messages` directly, which is correct only under the Postgres store.
  # Production runs MESSAGE_STORE_ADAPTER=scylla, where ScyllaAdapter.put_message/1 opens a Postgres
  # transaction ONLY to stage the event/webhook outbox — no row is ever inserted into `messages`. So
  # every real message returned no row: open/2 answered :not_found and the endpoint 404'd, while
  # state/2 answered :not_view_once and the download gate never engaged at all. Same
  # Postgres-vs-Scylla split that had just been fixed in the serialisers, one layer down.
  #
  # The view_once_opens LEDGER stays on Postgres by design — it is a PG table with no Scylla
  # counterpart, and it is authorization state rather than message content. Only the MESSAGE lookups
  # move.

  # media_id -> the earliest message referencing it, then the message itself. Two hops because the
  # media projection is keyed by media and the timeline by (conversation, message); the projection
  # carries no view_once, so only the second hop can answer the question.
  defp fetch_view_once(media_id) do
    with {:ok, ref} <- MessageStore.get_by_media_id(%{"media_id" => media_id}),
         conversation_id when is_binary(conversation_id) <- mget(ref, :conversation_id),
         message_id when is_binary(message_id) <- mget(ref, :message_id),
         {:ok, message} <- fetch_message_in(conversation_id, message_id),
         true <- mget(message, :view_once) == true do
      %{
        message_id: message_id,
        sender_user_id: mget(message, :sender_user_id),
        created_at: mget(message, :created_at)
      }
    else
      _ -> nil
    end
  end

  # The open path always knows its conversation — it is in the route — so the partition key is
  # available and this is a single point read on either store.
  defp fetch_message(conversation_id, message_id) do
    case fetch_message_in(conversation_id, message_id) do
      {:ok, message} ->
        %{
          conversation_id: mget(message, :conversation_id) || conversation_id,
          sender_user_id: mget(message, :sender_user_id),
          media_id: mget(message, :media_id),
          view_once: mget(message, :view_once) == true
        }

      _ ->
        nil
    end
  end

  defp fetch_message_in(conversation_id, message_id) do
    MessageStore.get_message(%{
      "conversation_id" => conversation_id,
      "message_id" => message_id
    })
  end

  defp mget(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp mget(_map, _key), do: nil

  defp opened?(message_id, viewer_id) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*)::int FROM view_once_opens " <>
          "WHERE message_id = $1::text::uuid AND user_id = $2::text::uuid",
        [message_id, viewer_id]
      )

    count > 0
  end

  defp existing_opened_at(message_id, viewer_id) do
    %{rows: [[opened_at]]} =
      Repo.query!(
        "SELECT opened_at FROM view_once_opens " <>
          "WHERE message_id = $1::text::uuid AND user_id = $2::text::uuid",
        [message_id, viewer_id]
      )

    opened_at
  end

  defp expired?(%DateTime{} = created_at) do
    DateTime.diff(DateTime.utc_now(), created_at, :second) > @expiry_days * 86_400
  end

  defp expired?(_), do: false
end
