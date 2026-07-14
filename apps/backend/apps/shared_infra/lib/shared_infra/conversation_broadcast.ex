defmodule SharedInfra.ConversationBroadcast do
  @moduledoc """
  The `conversation_updated` fan-out: a live inbox row on each participant's `user:<id>` topic.

  Lives in shared_infra, not the gateway, because THREE callers need it and they sit in different apps: the
  `/v1` controllers and the first-party controllers (api_gateway) and the realtime channel
  (realtime_gateway, which depends on shared_infra and cannot see ApiGatewayWeb). Rather than fork the
  fan-out per app — the surest way to get three subtly different unread counts — the endpoint module is a
  parameter (`endpoint.broadcast/3`; any Phoenix endpoint, no Phoenix dependency here).
  `ApiGatewayWeb.ConversationBroadcast` is a thin delegate that supplies `ApiGatewayWeb.Endpoint`.

  FOUR triggers feed it: `:message`, `:receipt`, `:title`, `:participant`. Every broadcast is tagged with its
  trigger in the CONV_UPDATED_DEBUG log line, so a silent failure names WHICH path broke instead of costing
  another debugging saga.

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
        error ->
          Logger.error(
            "CONV_UPDATED_DEBUG trigger=#{trigger} conv=#{conversation_id} FAILED: #{Exception.message(error)}"
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
  def unread_before(conversation_id, user_id) when is_binary(conversation_id) and is_binary(user_id) do
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

    # The removed member's final frame goes out regardless of the row fetch below — they HAVE no row to fetch
    # (inbox_rows requires an active participant), and their inbox must not keep a dead entry.
    if is_binary(removed_user_id) and removed_user_id != "" do
      Logger.info(
        "CONV_UPDATED_DEBUG trigger=#{trigger} conv=#{conversation_id} → user:#{removed_user_id} REMOVED"
      )

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
      Logger.info(
        "CONV_UPDATED_DEBUG trigger=#{trigger} conv=#{conversation_id} fanout=#{inspect(targets)}"
      )

      result
      |> rows()
      |> Enum.each(&broadcast_row(endpoint, &1, conversation_id, trigger, skip_if_unread))
    else
      other ->
        Logger.error(
          "CONV_UPDATED_DEBUG trigger=#{trigger} conv=#{conversation_id} row fetch failed: #{inspect(other)}"
        )

        :ok
    end
  end

  defp broadcast_row(endpoint, row, conversation_id, trigger, skip_if_unread) do
    user_id = cget(row, :user_id)
    unread = cget(row, :unread_count)

    cond do
      not (is_binary(user_id) and user_id != "") ->
        :ok

      # The count did not move (e.g. re-reading an already-read message) — an identical row is noise.
      not is_nil(skip_if_unread) and unread == skip_if_unread ->
        Logger.info(
          "CONV_UPDATED_DEBUG trigger=#{trigger} conv=#{conversation_id} → user:#{user_id} SKIPPED (unread unchanged at #{unread})"
        )

        :ok

      true ->
        Logger.info(
          "CONV_UPDATED_DEBUG trigger=#{trigger} conv=#{conversation_id} → user:#{user_id} unread=#{unread}"
        )

        endpoint.broadcast("user:" <> user_id, "conversation_updated", updated_row(row))
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

  # The broadcast payload = the inbox row, minus the routing key (user_id) that told us WHERE to send it.
  # String keys: this is a wire frame, and it must look identical whether the row came back from the
  # in-process adapter (atom keys) or over internal HTTP (string keys).
  defp updated_row(row) do
    row
    |> Map.drop([:user_id, "user_id"])
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  # A row may cross the ConversationClient boundary atom-keyed (in-process) or string-keyed (HTTP) — read either.
  defp cget(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp cget(_map, _key), do: nil
end
