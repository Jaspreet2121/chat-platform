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

  alias SharedInfra.InboxPreview

  @doc """
  Broadcast `conversation_updated` to a conversation's participants.

  Options:
    * `:only` — send to these user_ids instead of every participant. The `:receipt` trigger uses it: only the
      READER's count moved, so waking all N inboxes on every read would be pure noise.
    * `:skip_if_unread` — skip when the target's unread equals this number. The `:receipt` trigger snapshots
      the count BEFORE `mark_read` (see `unread_before/2`); re-reading an already-read message changes
      nothing, and an identical row must not be re-broadcast on every such call.
    * `:message` — the just-committed message that triggered this broadcast. Required on the `:message`
      trigger: its `created_at`, body/type and metadata content-type are what the frame's `updated_at`,
      `last_message_preview` and `last_message_kind` are composed from, because the row this fan-out
      re-reads has not been projected yet. See `apply_post_write_state/2`.
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
    message = Keyword.get(opts, :message)

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
      |> Enum.each(&broadcast_row(endpoint, &1, skip_if_unread, message))
    else
      other ->
        # No rows → NOBODY's inbox updated. Keep the trigger tag: it names which path went dark.
        Logger.error(
          "conversation_updated (#{trigger}) conv=#{conversation_id} row fetch failed: #{inspect(other)}"
        )

        :ok
    end
  end

  defp broadcast_row(endpoint, row, skip_if_unread, message) do
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
          row |> apply_post_write_state(message) |> updated_row()
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

  # THE POST-WRITE STATE — why re-reading the row is not enough.
  #
  # `updated_at`, `last_message_preview` and `last_message_kind` all come from
  # `conversations.last_message_*`, DENORMALISED columns (086). Under the Postgres store
  # `InboxProjection.record_message/1` maintains them inside the message's own transaction, so a read after
  # `create_message` returns is correct. Under the SCYLLA store — which is what production runs —
  # `ScyllaAdapter.put_message/1` writes the message to Scylla and only STAGES a Kafka event; the columns
  # are written later by the `InboxFromTopic` consumer, deliberately the single idempotent writer of the
  # unread increment. So this fan-out, which fires the moment `create_message` returns, re-reads a row the
  # projection has not reached yet and serialises the PREVIOUS message — one frame, one message behind,
  # with no corrected follow-up, while a later GET /conversations reads the same columns after the consumer
  # landed and is right.
  #
  # Applying the projection synchronously would fix the read but double-count unread (a second writer of
  # the increment, which InboxFromTopic's idempotency design forbids). So the caller carries the committed
  # message through and the frame is composed from IT: the authoritative facts from the write we just
  # performed, applied to the row we just read.
  #
  # ALL FOUR FIELDS MOVE TOGETHER, ON ONE DECISION — the timestamp comparison. That is what keeps the
  # frame internally consistent: if another message raced in between our write and this read, the row is
  # NEWER than ours and we touch nothing, so the client never sees a timestamp from one message beside a
  # preview from another. When the projection has landed the row already holds these same values and the
  # override is a no-op; when it has not, we supply what it will hold. Triggers that pass no `:message`
  # (`:receipt`, `:title`, `:participant`, `:pref`) are untouched.
  #
  # `unread_count` was the field that did NOT move with them — it passed through `updated_row/1` stale,
  # which is the n-1 badge (see `apply_pending_unread/2`). It is the same defect the preview trio was
  # fixed for, one field late.
  #
  # THE PREVIEW RULES ARE NOT REIMPLEMENTED HERE. `SharedInfra.InboxPreview` is the one definition;
  # conversation_service's row mapper delegates to the same module, so the live frame and a later refetch
  # cannot disagree. Sealed content is structurally unable to pass through it (108).
  defp apply_post_write_state(row, message) when is_map(message) do
    with {:ok, committed_at} <- parse_timestamp(created_at(message)),
         true <- newer?(committed_at, cget(row, :updated_at)) do
      body = Map.get(message, :body) || Map.get(message, "body")
      message_type = Map.get(message, :message_type) || Map.get(message, "message_type")

      row
      |> put_field(:updated_at, format_timestamp(committed_at))
      |> put_field(:last_message_preview, InboxPreview.preview_text(body, message_type))
      |> put_field(
        :last_message_kind,
        InboxPreview.message_kind(message_type, InboxPreview.content_type(message))
      )
      |> apply_pending_unread(message)
    else
      _ -> row
    end
  end

  defp apply_post_write_state(row, _message), do: row

  # THE FOURTH FIELD THE PROJECTION WILL WRITE. `unread_count` is maintained by the SAME consumer that
  # writes the preview columns, so on the not-yet-landed path it is stale for exactly the same reason and
  # by exactly one message — the frame showed the NEW preview beside the count from BEFORE it, so a
  # recipient with the chat closed saw a permanent n-1 badge that only a REST refetch corrected.
  #
  # WHY THIS CANNOT DOUBLE-COUNT. It is reachable only from inside the `newer?/2` branch above, and that
  # guard is the whole interlock: `newer?` is true only while the row's `updated_at` is OLDER than the
  # message we just committed, which is precisely the window before the consumer runs. Once the consumer
  # lands, @inbox_sql's `updated_at` IS this message's `last_message_at`, `newer?` compares equal (`:gt`
  # is false), the whole branch is skipped and the row — already carrying the projection's +1 — passes
  # through untouched. The three preview fields ride the same guard for the same reason; unread now
  # simply stops being the one field that opted out of it.
  #
  # THE SENDER IS EXCLUDED, mirroring the projection's own `cp.user_id <> $2` (InboxProjection
  # .record_message/1): your own message never raises your own unread. The row's `:user_id` is the
  # routing key `broadcast_row/4` fans on (dropped from the wire frame later by `updated_row/1`), so the
  # comparison is per-recipient and the sender's frame keeps its count unchanged.
  #
  # An unreadable sender or count leaves the row alone — a stale count is the bug we already had, while a
  # wrong +1 on the wrong row is a new one.
  defp apply_pending_unread(row, message) do
    with sender when is_binary(sender) and sender != "" <- sender_user_id(message),
         user_id when is_binary(user_id) and user_id != "" <- cget(row, :user_id),
         true <- user_id != sender,
         unread when is_integer(unread) <- cget(row, :unread_count) do
      put_field(row, :unread_count, unread + 1)
    else
      _ -> row
    end
  end

  defp created_at(message), do: Map.get(message, :created_at) || Map.get(message, "created_at")

  defp sender_user_id(message) do
    Map.get(message, :sender_user_id) || Map.get(message, "sender_user_id")
  end

  # Replace a field without leaving BOTH key shapes behind: the row may be atom- or string-keyed depending
  # on which side of the ConversationClient boundary it came from, so drop both and write back the style
  # the row already uses.
  defp put_field(row, key, value) do
    row
    |> Map.drop([key, to_string(key)])
    |> Map.put(key_style(row, key), value)
  end

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
