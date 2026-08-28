defmodule SharedInfra.ConversationBroadcast do
  @moduledoc """
  The `conversation_updated` fan-out: a live inbox row on each participant's `user:<id>` topic.

  Lives in shared_infra, not the gateway, because THREE callers need it and they sit in different apps: the
  `/v1` controllers and the first-party controllers (api_gateway) and the realtime channel
  (realtime_gateway, which depends on shared_infra and cannot see ApiGatewayWeb). Rather than fork the
  fan-out per app — the surest way to get three subtly different unread counts — the endpoint module is a
  parameter (`endpoint.broadcast/3`; any Phoenix endpoint, no Phoenix dependency here).
  `ApiGatewayWeb.ConversationBroadcast` is a thin delegate that supplies `ApiGatewayWeb.Endpoint`.

  FIVE triggers feed it: `:message`, `:receipt`, `:title`, `:participant`, `:pref` (a per-user archive/pin
  change — sent `only: [the acting user]`, since it's invisible to everyone else). The trigger is carried so a
  FAILURE names which of the four paths went dark — the success path is silent.

  PER-USER, not one shared row: unread_count, the preview and updated_at are ALL per-participant (a user who
  cleared their history sees a different preview AND a different count than the person beside them). So this
  asks `ConversationClient.inbox_rows` for one row per user — a single round-trip for the whole fan-out —
  instead of building one row and pasting per-user counts onto it.

  Fire-and-forget: `Task.start` + a rescue that LOGS (never swallows — a silent rescue is what made the last
  broken fan-out undiagnosable). A broadcast failure must never fail the action that triggered it.
  """

  require Logger

  @doc """
  Broadcast `conversation_updated` to a conversation's participants.

  Options:
    * `:only` — send to these user_ids instead of every participant. The `:receipt` trigger uses it: only the
      READER's count moved, so waking all N inboxes on every read would be pure noise.
    * `:skip_if_unread` — skip when the target's unread equals this number. The `:receipt` trigger snapshots
      the count BEFORE `mark_read` (see `unread_before/2`); re-reading an already-read message changes
      nothing, and an identical row must not be re-broadcast on every such call.
    * `:activity_at` — the just-committed message's `created_at`, used as a FLOOR on the row's
      `updated_at`. Required on the `:message` trigger; see `apply_activity_floor/2` for why the
      re-read alone is not enough.
    * `:removed_user_id` — also send a final `%{conversation_id, removed: true}` frame to a just-removed user.
      They are no longer an active participant, so `inbox_rows` returns NO row for them (the SQL requires
      `left_at IS NULL`); without this frame their inbox would keep a dead row until a refetch.
  """
  def broadcast_updated(endpoint, conversation_id, actor_user_id, trigger, opts \\ [])

  def broadcast_updated(endpoint, conversation_id, actor_user_id, trigger, opts)
      when is_atom(endpoint) and is_binary(conversation_id) and is_binary(actor_user_id) and
             is_atom(trigger) do
    Task.start(fn ->
      try do
        do_broadcast_updated(endpoint, conversation_id, actor_user_id, trigger, opts)
      rescue
        # Fire-and-forget must never fail the caller — but it must not VANISH either. A silent rescue is
        # exactly what made the last broken fan-out undiagnosable, so this one line stays. The trigger tag
        # names which of the four paths broke.
        error ->
          Logger.error(
            "conversation_updated (#{trigger}) conv=#{conversation_id} broadcast failed: #{Exception.message(error)}"
          )

          :ok
      end
    end)

    :ok
  end

  def broadcast_updated(_endpoint, _conversation_id, _actor_user_id, _trigger, _opts), do: :ok

  @doc """
  A user's CURRENT unread count for a conversation — snapshotted BEFORE a `mark_read` so the receipt trigger
  can tell a real change from a no-op (pass it as `:skip_if_unread`).

  Returns nil when it can't be determined, which simply means "don't skip": we would rather send one
  redundant row than drop a real one.

  Synchronous, and only on the receipt path. It exists because `mark_read` upserts and returns the receipt
  whether or not anything changed, so it cannot tell us itself. The cheaper future fix is to have `mark_read`
  report whether the upsert actually transitioned the receipt, which removes this pre-read entirely.
  """
  def unread_before(conversation_id, user_id)
      when is_binary(conversation_id) and is_binary(user_id) do
    case SharedInfra.ConversationClient.inbox_rows(%{
           "conversation_id" => conversation_id,
           "user_ids" => [user_id]
         }) do
      {:ok, result} ->
        result
        |> rows()
        |> Enum.find(&(cget(&1, :user_id) == user_id))
        |> case do
          nil -> nil
          row -> cget(row, :unread_count)
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  def unread_before(_conversation_id, _user_id), do: nil

  defp do_broadcast_updated(endpoint, conversation_id, actor_user_id, trigger, opts) do
    removed_user_id = Keyword.get(opts, :removed_user_id)
    skip_if_unread = Keyword.get(opts, :skip_if_unread)
    activity_at = Keyword.get(opts, :activity_at)

    # The removed member's final frame goes out regardless of the row fetch below — they HAVE no row to fetch
    # (inbox_rows requires an active participant), and their inbox must not keep a dead entry.
    if is_binary(removed_user_id) and removed_user_id != "" do
      endpoint.broadcast("user:" <> removed_user_id, "conversation_updated", %{
        "conversation_id" => conversation_id,
        "removed" => true
      })
    end

    with {:ok, targets} <- fan_out_targets(conversation_id, actor_user_id, opts),
         {:ok, result} <-
           SharedInfra.ConversationClient.inbox_rows(%{
             "conversation_id" => conversation_id,
             "user_ids" => targets
           }) do
      result
      |> rows()
      |> Enum.each(&broadcast_row(endpoint, &1, skip_if_unread, activity_at))
    else
      other ->
        # No rows → NOBODY's inbox updated. Keep the trigger tag: it names which path went dark.
        Logger.error(
          "conversation_updated (#{trigger}) conv=#{conversation_id} row fetch failed: #{inspect(other)}"
        )

        :ok
    end
  end

  defp broadcast_row(endpoint, row, skip_if_unread, activity_at) do
    user_id = cget(row, :user_id)
    unread = cget(row, :unread_count)

    cond do
      not (is_binary(user_id) and user_id != "") ->
        :ok

      # The count did not move (e.g. re-reading an already-read message) — an identical row is noise.
      not is_nil(skip_if_unread) and unread == skip_if_unread ->
        :ok

      true ->
        endpoint.broadcast(
          "user:" <> user_id,
          "conversation_updated",
          row |> apply_activity_floor(activity_at) |> updated_row()
        )
    end
  end

  # Whom to send to: an explicit `:only` list (the receipt trigger), else every ACTIVE participant — read from
  # get_conversation, the same participant source the message fan-out already uses. The ACTOR is INCLUDED: a
  # sender's own row still changes (new preview, new updated_at), it just never gains unread (the SQL excludes
  # your own messages from your own count).
  defp fan_out_targets(conversation_id, actor_user_id, opts) do
    case Keyword.get(opts, :only) do
      [_ | _] = only ->
        {:ok, only}

      _ ->
        case SharedInfra.ConversationClient.get_conversation(%{
               "conversation_id" => conversation_id,
               "user_id" => actor_user_id
             }) do
          {:ok, conversation} ->
            ids =
              (cget(conversation, :participants) || [])
              |> Enum.map(&cget(&1, :user_id))
              |> Enum.reject(&(is_nil(&1) or &1 == ""))

            {:ok, ids}

          other ->
            other
        end
    end
  end

  defp rows(result) when is_map(result), do: cget(result, :rows) || []
  defp rows(_result), do: []

  # THE POST-WRITE FLOOR — why re-reading the row is not enough.
  #
  # The frame's `updated_at` comes from `conversations.last_message_at`, a DENORMALISED column (086).
  # Under the Postgres store `InboxProjection.record_message/1` maintains it inside the message's own
  # transaction, so a read after `create_message` returns is correct. Under the SCYLLA store — which is
  # what production runs — `ScyllaAdapter.put_message/1` writes the message to Scylla and only STAGES a
  # Kafka event; the column is written later by the `InboxFromTopic` consumer, deliberately the single
  # idempotent writer of the unread increment. So this fan-out, which fires the moment `create_message`
  # returns, re-reads a row the projection has not reached yet and serialises the PREVIOUS message's
  # timestamp. One frame, one message behind, with no corrected follow-up — exactly what was captured on
  # device — while a later GET /conversations reads the same column after the consumer landed and is right.
  #
  # Applying the projection synchronously would fix the read but double-count unread (it would add a
  # second writer of the increment, which InboxFromTopic's idempotency design forbids). So instead the
  # caller carries the committed message's own `created_at` through and it is used as a FLOOR here: the
  # authoritative value from the write we just performed, applied to the row we just read.
  #
  # A FLOOR, never an overwrite. When the projection HAS landed the row already carries this timestamp (or
  # a newer one, if another message raced in) and nothing changes — so a fresh row is never dragged
  # backwards, and the triggers that pass no `:activity_at` (`:receipt`, `:title`, `:participant`, `:pref`)
  # are untouched.
  #
  # PREVIEW STALENESS IS NOT FIXED HERE, and that is deliberate: `last_message_body/type` come from the
  # same unprojected row, but rebuilding the preview would mean copying conversation_service's
  # `preview_text/2` + `message_kind/2` rules across a release boundary into shared_infra — the second
  # copy that @inbox_sql's own comment warns drifts. The ordering key is what broke inboxes; the preview
  # correction belongs with those rules, not beside them.
  defp apply_activity_floor(row, activity_at) do
    with {:ok, floor} <- parse_timestamp(activity_at),
         current = cget(row, :updated_at),
         true <- newer?(floor, current) do
      row
      |> Map.drop([:updated_at, "updated_at"])
      |> Map.put(key_style(row, :updated_at), format_timestamp(floor))
    else
      _ -> row
    end
  end

  # The row may be atom- or string-keyed depending on which side of the ConversationClient boundary it
  # came from; write the replacement back in the SAME style so nothing downstream sees both.
  defp key_style(row, key) do
    if Map.has_key?(row, key), do: key, else: to_string(key)
  end

  defp newer?(floor, current) do
    case parse_timestamp(current) do
      {:ok, current_dt} -> DateTime.compare(floor, current_dt) == :gt
      _ -> true
    end
  end

  defp parse_timestamp(%DateTime{} = value), do: {:ok, value}

  defp parse_timestamp(value) when is_binary(value) and value != "" do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> :error
    end
  end

  defp parse_timestamp(_value), do: :error

  # Byte-identical to @inbox_sql's to_char format, so a floored frame and a projected one are
  # indistinguishable on the wire.
  defp format_timestamp(%DateTime{} = datetime) do
    # The precision is FORCED to 6 digits first. `%f` renders whatever precision the DateTime carries, so a
    # timestamp parsed from a fraction-less ISO string ({0, 0}) would render "...:40.0Z" — a different
    # string shape from the one @inbox_sql's to_char always produces, and clients parse this field.
    %{DateTime.shift_zone!(datetime, "Etc/UTC") | microsecond: {elem(datetime.microsecond, 0), 6}}
    |> Calendar.strftime("%Y-%m-%dT%H:%M:%S.%f")
    |> Kernel.<>("Z")
  end

  # The broadcast payload = the inbox row, minus the routing key (user_id) that told us WHERE to send it.
  # String keys: this is a wire frame, and it must look identical whether the row came back from the
  # in-process adapter (atom keys) or over internal HTTP (string keys).
  #
  # This builder passes through EVERY remaining row field indiscriminately, so it must also drop
  # `group_avatar_object_key` — a raw object-store path that must never reach a client (Android contract §8.6;
  # the client renders the group photo from the presigned `group_avatar_url` / the media_id, never the object
  # key). The conversation_service row no longer emits it (Conversations.inbox_rows — root cause); this is the
  # wire-frame guard so a future row source can't reintroduce the leak here.
  defp updated_row(row) do
    row
    |> Map.drop([:user_id, "user_id", :group_avatar_object_key, "group_avatar_object_key"])
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  # A row may cross the ConversationClient boundary atom-keyed (in-process) or string-keyed (HTTP) — read either.
  defp cget(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp cget(_map, _key), do: nil
end
