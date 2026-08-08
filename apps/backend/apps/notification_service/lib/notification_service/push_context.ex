defmodule NotificationService.PushContext do
  @moduledoc """
  The transport-INDEPENDENT half of a push: what the notification says and whether it may be sent
  at all. Extracted from `NotificationService.PushSender` when the FCM leg arrived (Phase 2) so the
  two transports cannot drift — a web-push and an Android push for the same message must carry the
  same preview text and honour the same mute, or the same account gets two different stories on two
  devices.

  Every function is BEST-EFFORT — no error raises inside a fan-out. Most resolve to the PERMISSIVE
  default (`muted?` → false, i.e. SEND), because a hiccup must not silently drop a push.
  `message_preview_fields/2` is the ONE EXCEPTION and resolves to SUPPRESS: it is the only function
  whose failure would put words in the notification that the message does not contain.

  All of these read the shared Postgres EXCEPT `message_preview_fields/2`, which reads the message
  store through `SharedInfra.MessageClient` — over HTTP to message-service in production.

  ## KNOWN DEGRADATION UNDER `MESSAGE_STORE_ADAPTER=scylla` — live from the moment of cutover

  Two functions here still read the Postgres `messages` table, which stops receiving writes at the
  cutover. Their best-effort fallbacks then fire silently:

    * `unread_count/2` → falls back to `1`, so the collapse label always says one message.
    * `total_unread_count/1` → falls back to `0`, so the app-icon badge reads zero.

  `message_preview_fields/2` USED TO BE THE THIRD AND IS NOT ANYMORE. It read Postgres, got nothing
  after the cutover, and fell through `preview/3` to its catch-all so every notification read
  **"New message"** — not an empty push, a push that LOOKED LIKE A WORKING NOTIFICATION while
  carrying no content, which is worse because nothing about it invited investigation. It now reads
  the message STORE through `SharedInfra.MessageClient`, and when that read fails it suppresses the
  push and logs at `:error` instead of inventing a body.

  `sender_name/1` and `group_name/1` are unaffected — `user_profiles` and `conversations` stay
  Postgres-owned.

  THE HONEST FIX for the two counters is NOT a store read: they are aggregates, and computing them
  from Scylla means a partition scan per recipient. They should come from the inbox projection's
  maintained `conversation_participants.unread_count`, which the topic-fed projection already keeps.
  Tracked as its own slice.

  ## THIS APP NOW DEPENDS ON MESSAGE-SERVICE AT RUNTIME, AND THAT IS A DEPLOYMENT REQUIREMENT

  `message_preview_fields/2` calls `SharedInfra.MessageClient.get_message/1`. The notification
  container MUST therefore set `MESSAGE_CLIENT_ADAPTER=http` and `MESSAGE_SERVICE_URL`. There is no
  working default: `MESSAGE_CLIENT_ADAPTER` defaults to `MessageService.MessageClientInProcess`,
  which is NOT in this release (`[shared_infra, notification_service]` — see the umbrella `mix.exs`),
  so the call raises `UndefinedFunctionError`. That raise is caught and treated as a failed
  read-back — logged at `:error`, push suppressed — so a misconfigured container degrades loudly
  instead of crashing the fan-out, but EVERY preview is suppressed until it is fixed.

  The trade this accepted: before, a message-service outage left previews working off the shared
  Postgres; now they are suppressed. That independence did not survive the Scylla cutover anyway —
  after it the Postgres read returns nothing and every push already said "New message". The real
  choice was "previews work, or they say New message forever". Both containers also run on one host
  on `chatnet`, so a message-service outage generally means the whole stack is down, and then there
  is nothing to push about.

  What deliberately stayed behind in each sender: the payload envelope, the credential check, the
  device/subscription lookup and the dead-endpoint pruning. Those are transport-shaped and have no
  business being shared — including the web-push avatar-icon URL, which exists only because a
  service worker fetches an icon with no session.
  """

  require Logger

  alias NotificationService.Repo

  @doc """
  Per-event, per-transport-independent context: the sender's display name, the message preview and
  (groups only) the group name. One lookup each — per-recipient bits (mute, unread) are resolved in
  the delivery loop because they differ per recipient.
  """
  def message_context(attrs) do
    case message_preview_fields(attrs.conversation_id, attrs.message_id) do
      :no_preview ->
        :no_preview

      {:ok, %{body: body, message_type: message_type, content_type: content_type}} ->
        {:ok,
         %{
           sender: sender_name(attrs.sender_user_id),
           preview: preview(body, message_type, content_type),
           group_name: group_name(attrs.conversation_id)
         }}
    end
  end

  @doc """
  Mute: skip a recipient whose participant row for this conversation is muted right now
  (muted_until > now(); 'infinity' = always). In-app notification rows are unaffected.
  """
  def muted?(conversation_id, user_id) do
    case Repo.query(
           "SELECT 1 FROM conversation_participants " <>
             "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid " <>
             "AND muted_until IS NOT NULL AND muted_until > now()",
           [conversation_id, user_id]
         ) do
      {:ok, %{num_rows: n}} -> n > 0
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc """
  The recipient's current unread count for this conversation (their read receipts + clear/auto-delete
  window respected) — used for the collapse label. Best-effort: on any error, 1 (show the single msg).
  """
  def unread_count(conversation_id, user_id) do
    case Repo.query(
           "SELECT count(*) FROM messages m " <>
             "JOIN conversation_participants cp " <>
             "  ON cp.conversation_id = m.conversation_id AND cp.user_id = $2::text::uuid " <>
             "WHERE m.conversation_id = $1::text::uuid AND m.deleted_at IS NULL " <>
             "AND m.sender_user_id <> $2::text::uuid " <>
             "AND (cp.cleared_before IS NULL OR m.created_at > cp.cleared_before) " <>
             "AND (cp.auto_delete_seconds IS NULL " <>
             "     OR m.created_at > now() - make_interval(secs => cp.auto_delete_seconds)) " <>
             "AND NOT EXISTS (SELECT 1 FROM message_receipts r " <>
             "  WHERE r.conversation_id = m.conversation_id AND r.message_id = m.message_id " <>
             "  AND r.user_id = $2::text::uuid AND (r.status = 'read' OR r.read_at IS NOT NULL))",
           [conversation_id, user_id]
         ) do
      {:ok, %{rows: [[count]]}} when is_integer(count) and count > 0 -> count
      _ -> 1
    end
  rescue
    _ -> 1
  end

  @doc """
  The recipient's TOTAL unread across ALL their active conversations (same per-conversation window
  rules, summed) — the app-icon badge while the app is closed. Best-effort: on any error, 0 (the app
  reconciles the true total on next focus, so a miss self-corrects).
  """
  def total_unread_count(user_id) do
    # Muted chats still count toward the badge (mute silences the alert, not the count) — matches
    # the app-side reconciler which sums the chat-list unread without a mute filter.
    case Repo.query(
           "SELECT count(*) FROM messages m " <>
             "JOIN conversation_participants cp " <>
             "  ON cp.conversation_id = m.conversation_id AND cp.user_id = $1::text::uuid " <>
             "     AND cp.left_at IS NULL " <>
             "WHERE m.deleted_at IS NULL AND m.sender_user_id <> $1::text::uuid " <>
             "AND (cp.cleared_before IS NULL OR m.created_at > cp.cleared_before) " <>
             "AND (cp.auto_delete_seconds IS NULL " <>
             "     OR m.created_at > now() - make_interval(secs => cp.auto_delete_seconds)) " <>
             "AND NOT EXISTS (SELECT 1 FROM message_receipts r " <>
             "  WHERE r.conversation_id = m.conversation_id AND r.message_id = m.message_id " <>
             "  AND r.user_id = $1::text::uuid AND (r.status = 'read' OR r.read_at IS NOT NULL))",
           [user_id]
         ) do
      {:ok, %{rows: [[count]]}} when is_integer(count) and count >= 0 -> count
      _ -> 0
    end
  rescue
    _ -> 0
  end

  @doc "Group name for a group conversation; nil for a DM (no group_profiles row)."
  def group_name(conversation_id) do
    case Repo.query(
           "SELECT gp.name FROM conversations c " <>
             "LEFT JOIN group_profiles gp ON gp.conversation_id = c.id " <>
             "WHERE c.id = $1::text::uuid AND c.type = 'group'",
           [conversation_id]
         ) do
      {:ok, %{rows: [[name]]}} when is_binary(name) and name != "" -> name
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Body / message_type / content_type for the preview. The Kafka payload carries no body.

  Reads through `SharedInfra.MessageClient.get_message/1` — the message store, whichever adapter is
  configured — NOT the shared Postgres. That is the point: the Postgres read stopped working at the
  Scylla cutover and degraded every push to the body "New message" silently.

  Returns `{:ok, fields}` or `:no_preview`. `:no_preview` SUPPRESSES THE PUSH ENTIRELY (see
  `message_context/1`) rather than falling through `preview/3` to "New message" — a notification that
  lies about its content is worse than no notification, because it looks like it worked.

  `:no_preview` is an explicit atom rather than the old nil-triple sentinel for a reason: a real text
  message with an empty body legitimately previews as "New message", and that must stay distinct from
  "we could not read the message at all". Overloading one value for both is how the earlier silent
  degradation hid.

  ## The two failure outcomes are logged DIFFERENTLY, on purpose

    * ABSENT or DELETED — a normal outcome. The message really is gone; not pushing is correct.
      Logged at `:info`.
    * READ FAILED — client error, timeout, `:message_unavailable`, or the adapter module not being
      present in this release. NOT normal: it means a dependency is broken and every push in the
      meantime is being suppressed. Logged at `:error`.

  If those two read the same in the logs, an operator cannot tell a deleted message from a broken
  message-service. That distinction is the whole reason this function logs at all.

  ## THERE IS NO CONTENT FILTER HERE, AND THAT IS SAFE ONLY BECAUSE THE PUSH IS IMMEDIATE

  This read is by `(conversation_id, message_id)` alone. It does NOT check `cleared_before`,
  `auto_delete_seconds`, `user_hidden_messages`, or blocks — every visibility rule the transcript and
  the pinned-message list apply. The only gate on this path is `muted?/2`, which is an alert
  preference, not a content rule.

  That is currently correct, for one reason: the push fires IMMEDIATELY on `message.created`. At that
  instant the message is new — not deleted, inside every window by definition, and a blocked sender's
  message never existed (block-drop happens at send). The filter is unnecessary because there is
  nothing yet to filter.

  ### What breaks if that immediacy ever goes

  The consumer group behind this path uses `begin_offset: :latest`
  (notification_service/application.ex). Change it to `:earliest`, or replay this group for any other
  reason, and old events are re-processed: this query would happily return the body of a message that
  has since been DELETED or aged out of a recipient's auto-delete window, and push it to a handset.
  Push is fire-and-forget to FCM — there is no recall. That is content leaving the device's control
  after the system promised to remove it.

  So: if `begin_offset` for this group ever changes, or any replay/backfill path is added, THE FILTER
  MUST BE ADDED FIRST.

  ### The inbox consumer's `:earliest` is deliberate and must NOT be copied onto this group

  `message-service-inbox-projection` replays from `:earliest` on purpose — a stale unread count is
  self-correcting, and skipping a backlog silently loses counts. This group is the opposite: a stale
  push has already reached a phone. They are separate consumer groups on the same topic and Kafka
  tracks offsets per group, so the difference is expressible and intended. Do not "harmonise" them.
  """
  def message_preview_fields(conversation_id, message_id) do
    SharedInfra.MessageClient.get_message(%{
      "conversation_id" => conversation_id,
      "message_id" => message_id
    })
    |> classify(conversation_id, message_id)
  rescue
    # The adapter module itself may not exist. `MESSAGE_CLIENT_ADAPTER` defaults to
    # `MessageService.MessageClientInProcess`, which is NOT in notification_service's release
    # (`[shared_infra, notification_service]`), so a container missing MESSAGE_CLIENT_ADAPTER=http
    # raises UndefinedFunctionError here on EVERY push. That is a broken dependency, not an absent
    # message: it must be loud and it must not take the fan-out down with it.
    error -> read_failed(conversation_id, message_id, error)
  catch
    :exit, reason -> read_failed(conversation_id, message_id, {:exit, reason})
  end

  defp classify({:ok, %{deleted_at: deleted_at}}, conversation_id, message_id)
       when not is_nil(deleted_at) do
    Logger.info(
      "push preview: message already DELETED, suppressing push " <>
        "conversation=#{conversation_id} message=#{message_id}"
    )

    :no_preview
  end

  defp classify({:ok, message}, _conversation_id, _message_id) do
    {:ok,
     %{
       body: Map.get(message, :body),
       message_type: Map.get(message, :message_type),
       content_type: content_type(Map.get(message, :metadata))
     }}
  end

  defp classify({:error, :message_not_found}, conversation_id, message_id) do
    Logger.info(
      "push preview: message ABSENT, suppressing push " <>
        "conversation=#{conversation_id} message=#{message_id}"
    )

    :no_preview
  end

  defp classify({:error, reason}, conversation_id, message_id),
    do: read_failed(conversation_id, message_id, reason)

  # Anything the boundary can return that is not a message and not a clean "not found".
  defp classify(other, conversation_id, message_id),
    do: read_failed(conversation_id, message_id, {:unexpected_result, other})

  defp read_failed(conversation_id, message_id, reason) do
    Logger.error(
      "push preview READ FAILED, suppressing push (dependency broken, NOT a missing message) " <>
        "conversation=#{conversation_id} message=#{message_id} reason=#{inspect(reason)}"
    )

    :no_preview
  end

  # `metadata` is string-keyed by contract: the HTTP adapter decodes it with `skip_atomize` precisely
  # so arbitrary atoms are never minted from user input, and Postgres jsonb gives string keys too.
  defp content_type(%{"content_type" => content_type}) when is_binary(content_type),
    do: content_type

  defp content_type(_), do: nil

  def sender_name(sender_user_id) do
    case Repo.query(
           "SELECT display_name FROM user_profiles WHERE user_id = $1",
           [dump_uuid(sender_user_id)]
         ) do
      {:ok, %{rows: [[name]]}} when is_binary(name) and name != "" -> name
      _ -> "New message"
    end
  end

  @doc """
  Same media labels the chat list/toasts use. PURE — this is the function both transports call, and
  it is why an Android notification and a browser notification read identically.
  """
  def preview(body, message_type, content_type)

  def preview(body, "text", _content_type) when is_binary(body) and body != "", do: body

  def preview(_body, "location", _content_type), do: "📍 Location"

  def preview(_body, "live_location", _content_type), do: "📍 Live location"

  def preview(_body, "media", content_type) do
    ct = to_string(content_type)

    cond do
      String.starts_with?(ct, "image/") -> "📷 Photo"
      String.starts_with?(ct, "audio/") -> "🎤 Voice message"
      String.starts_with?(ct, "video/") -> "🎬 Video"
      true -> "📎 Attachment"
    end
  end

  def preview(body, _type, _content_type) when is_binary(body) and body != "", do: body
  def preview(_body, _type, _content_type), do: "New message"

  @doc "Text uuid → binary for a bytea-typed parameter; passes the value through when not a uuid."
  def dump_uuid(value) do
    case Ecto.UUID.dump(value) do
      {:ok, binary} -> binary
      :error -> value
    end
  end
end
