defmodule NotificationService.PushContext do
  @moduledoc """
  The transport-INDEPENDENT half of a push: what the notification says and whether it may be sent
  at all. Extracted from `NotificationService.PushSender` when the FCM leg arrived (Phase 2) so the
  two transports cannot drift — a web-push and an Android push for the same message must carry the
  same preview text and honour the same mute, or the same account gets two different stories on two
  devices.

  Everything here is a READ against the shared Postgres (same precedent as the participant
  read-model) and every function is BEST-EFFORT: any error resolves to the permissive default
  (`muted?` → false, i.e. SEND) rather than raising inside a fan-out.

  ## KNOWN DEGRADATION UNDER `MESSAGE_STORE_ADAPTER=scylla` — live from the moment of cutover

  Three functions here read the Postgres `messages` table, which stops receiving writes at the
  cutover. Their best-effort fallbacks then fire silently:

    * `message_preview_fields/1` → the nil-triple, so `preview/3` falls through every clause to its
      catch-all and the notification reads **"New message"**. NOT an empty push — a push that LOOKS
      LIKE A WORKING NOTIFICATION while carrying no content. That is worse than empty, because
      nothing about it invites investigation.
    * `unread_count/2` → falls back to `1`, so the collapse label always says one message.
    * `total_unread_count/1` → falls back to `0`, so the app-icon badge reads zero.

  `sender_name/1` and `group_name/1` are unaffected — `user_profiles` and `conversations` stay
  Postgres-owned.

  THE HONEST FIX for the two counters is NOT a store read: they are aggregates, and computing them
  from Scylla means a partition scan per recipient. They should come from the inbox projection's
  maintained `conversation_participants.unread_count`, which the topic-fed projection already keeps.
  Tracked as its own slice.

  THE PREVIEW is a single-message read and CAN come from the store — but not yet, and not from here.
  `SharedInfra.MessageClient.get_message/1` now EXISTS (added as the capability, with no caller), so
  the missing half is purely deployment: this app cannot reach message_service. Its release carries
  only shared_infra + notification_service, so the DEFAULT adapter
  (`MessageService.MessageClientInProcess`) is not even loaded in that container, and it has no
  `MESSAGE_CLIENT_ADAPTER`/`MESSAGE_SERVICE_URL` set. Until the notification container is configured
  for the HTTP adapter — a topology change with its own trade, since today a message-service outage
  leaves these previews working off the shared DB — this stays a Repo read on the shared database.

  What deliberately stayed behind in each sender: the payload envelope, the credential check, the
  device/subscription lookup and the dead-endpoint pruning. Those are transport-shaped and have no
  business being shared — including the web-push avatar-icon URL, which exists only because a
  service worker fetches an icon with no session.
  """

  alias NotificationService.Repo

  @doc """
  Per-event, per-transport-independent context: the sender's display name, the message preview and
  (groups only) the group name. One lookup each — per-recipient bits (mute, unread) are resolved in
  the delivery loop because they differ per recipient.
  """
  def message_context(attrs) do
    %{body: body, message_type: message_type, content_type: content_type} =
      message_preview_fields(attrs.message_id)

    %{
      sender: sender_name(attrs.sender_user_id),
      preview: preview(body, message_type, content_type),
      group_name: group_name(attrs.conversation_id)
    }
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

  ## THERE IS NO CONTENT FILTER HERE, AND THAT IS SAFE ONLY BECAUSE THE PUSH IS IMMEDIATE

  This query is a bare `WHERE message_id = $1`. It does NOT check `deleted_at`, `cleared_before`,
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
  def message_preview_fields(message_id) do
    case Repo.query(
           "SELECT body, message_type, metadata->>'content_type' FROM messages WHERE message_id = $1",
           [dump_uuid(message_id)]
         ) do
      {:ok, %{rows: [[body, message_type, content_type]]}} ->
        %{body: body, message_type: message_type, content_type: content_type}

      _ ->
        %{body: nil, message_type: nil, content_type: nil}
    end
  end

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
