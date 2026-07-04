defmodule NotificationService.PushSender do
  @moduledoc """
  The web-push SENDER leg (Phase 1): after the existing message_created fan-out (sender-excluded,
  idempotent), deliver a VAPID-signed web-push (RFC 8291/8292 via web_push_encryption) to each
  recipient's registered browser subscriptions.

  Runs OUTSIDE the fan-out transaction, fire-and-forget per subscription — a slow/failed endpoint
  never blocks the consumer or other recipients. Expired endpoints (404/410) are pruned. Disabled
  cleanly when VAPID keys aren't configured (logs once per send attempt at debug).

  Reads the shared Postgres directly (same precedent as the participant read-model):
    * push_subscriptions — the recipients' browser endpoints (owned/written by the auth service);
    * messages — the preview body/type (the Kafka payload deliberately carries no body);
    * user_profiles — the sender's display name.
  READ-only everywhere except deleting dead push_subscriptions rows. Never touches messages.
  """

  require Logger

  alias NotificationService.Repo

  @doc "Fire-and-forget push fan-out for an applied message_created event."
  def push_message_created(attrs, recipients) do
    if vapid_configured?() and recipients != [] do
      Task.start(fn -> deliver(attrs, recipients) end)
    end

    :ok
  end

  defp deliver(attrs, recipients) do
    # Shared per-event context (one lookup each): the sender's name, the message preview, and — for a
    # GROUP — the group name. Per-recipient bits (mute, unread count) are resolved in the loop.
    context = message_context(attrs)

    for recipient <- recipients,
        not muted?(attrs.conversation_id, recipient),
        # Presence-aware suppression: skip a recipient currently VIEWING this conversation (app open +
        # chat active — the realtime gateway keeps a short-TTL Redis marker). The in-app path already
        # updates them, so a push would be redundant. FAIL-OPEN: any Redis miss/error → present?=false
        # → we SEND (a redundant push beats a missed one; never suppressed by a Redis hiccup).
        not SharedInfra.PresenceMarker.present?(recipient, attrs.conversation_id) do
      payload =
        build_payload(
          context,
          attrs,
          unread_count(attrs.conversation_id, recipient),
          total_unread_count(recipient)
        )

      for subscription <- subscriptions_for(recipient) do
        send_one(subscription, payload)
      end
    end
  rescue
    error -> Logger.warning("web-push deliver raised, ignored: #{inspect(error)}")
  end

  defp message_context(attrs) do
    %{body: body, message_type: message_type, content_type: content_type} =
      message_preview_fields(attrs.message_id)

    %{
      sender: sender_name(attrs.sender_user_id),
      preview: preview(body, message_type, content_type),
      group_name: group_name(attrs.conversation_id)
    }
  end

  # Per-recipient payload. DM → title = sender, body = preview. GROUP → "Sender in GroupName" as the
  # title (who + where), preview as the body. `unread` lets the SW collapse a burst into "N new
  # messages" (the tag already coalesces same-conversation notifications). `badgeCount` is the
  # recipient's TOTAL unread across all conversations → the SW sets the PWA app-icon badge while the
  # app is closed (the app itself reconciles authoritatively on focus). No avatar (presign/expiry).
  defp build_payload(context, attrs, unread, badge_count) do
    title =
      if context.group_name,
        do: "#{context.sender} in #{context.group_name}",
        else: context.sender

    Jason.encode!(%{
      title: title,
      body: context.preview,
      tag: "conversation:#{attrs.conversation_id}",
      data: %{
        conversation_id: attrs.conversation_id,
        message_id: attrs.message_id,
        unread: unread,
        badgeCount: badge_count
      }
    })
  end

  # WEB-PUSH mute: skip a recipient whose participant row for this conversation is muted right now
  # (muted_until > now(); 'infinity' = always). In-app notification rows are unaffected.
  defp muted?(conversation_id, user_id) do
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

  # The recipient's current unread count for this conversation (their read receipts + clear/auto-delete
  # window respected) — used for the collapse label. Best-effort: on any error, 1 (show the single msg).
  defp unread_count(conversation_id, user_id) do
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

  # The recipient's TOTAL unread across ALL their active conversations (same per-conversation window
  # rules, summed) — the SW sets this as the app-icon badge while the app is closed. Best-effort: on
  # any error, 0 (the app reconciles the true total on next focus, so a miss self-corrects).
  defp total_unread_count(user_id) do
    case Repo.query(
           "SELECT count(*) FROM messages m " <>
             "JOIN conversation_participants cp " <>
             "  ON cp.conversation_id = m.conversation_id AND cp.user_id = $1::text::uuid " <>
             "     AND cp.left_at IS NULL " <>
             "WHERE m.deleted_at IS NULL AND m.sender_user_id <> $1::text::uuid " <>
             # Muted chats still count toward the badge (mute silences the alert, not the count) —
             # matches the app-side reconciler which sums the chat-list unread without a mute filter.
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

  # Group name for the "Sender in GroupName" title; nil for a DM (no group_profiles row).
  defp group_name(conversation_id) do
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

  defp send_one(%{id: id, endpoint: endpoint, p256dh: p256dh, auth: auth}, payload) do
    subscription = %{endpoint: endpoint, keys: %{p256dh: p256dh, auth: auth}}

    case WebPushEncryption.send_web_push(payload, subscription) do
      {:ok, %{status_code: status}} when status in [404, 410] ->
        prune(id)

      {:ok, %{status_code: status}} when status >= 400 ->
        Logger.warning("web-push rejected (#{status}) for subscription #{id}")

      {:ok, _response} ->
        :ok

      {:error, reason} ->
        Logger.warning("web-push send failed for subscription #{id}: #{inspect(reason)}")
    end
  rescue
    error -> Logger.warning("web-push send raised for subscription #{id}: #{inspect(error)}")
  end

  defp subscriptions_for(user_id) do
    case Repo.query(
           "SELECT id::text, endpoint, p256dh, auth FROM push_subscriptions WHERE user_id = $1",
           [dump_uuid(user_id)]
         ) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [id, endpoint, p256dh, auth] ->
          %{id: id, endpoint: endpoint, p256dh: p256dh, auth: auth}
        end)

      _ ->
        []
    end
  end

  # Dead endpoint (unsubscribed/expired) → drop the row so we stop paying for it.
  defp prune(id) do
    Repo.query("DELETE FROM push_subscriptions WHERE id = $1::text::uuid", [id])
    :ok
  end

  defp message_preview_fields(message_id) do
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

  defp sender_name(sender_user_id) do
    case Repo.query(
           "SELECT display_name FROM user_profiles WHERE user_id = $1",
           [dump_uuid(sender_user_id)]
         ) do
      {:ok, %{rows: [[name]]}} when is_binary(name) and name != "" -> name
      _ -> "New message"
    end
  end

  # Same media labels the chat list/toasts use.
  defp preview(body, "text", _content_type) when is_binary(body) and body != "", do: body

  defp preview(_body, "media", content_type) do
    ct = to_string(content_type)

    cond do
      String.starts_with?(ct, "image/") -> "📷 Photo"
      String.starts_with?(ct, "audio/") -> "🎤 Voice message"
      String.starts_with?(ct, "video/") -> "🎬 Video"
      true -> "📎 Attachment"
    end
  end

  defp preview(body, _type, _content_type) when is_binary(body) and body != "", do: body
  defp preview(_body, _type, _content_type), do: "New message"

  defp dump_uuid(value) do
    case Ecto.UUID.dump(value) do
      {:ok, binary} -> binary
      :error -> value
    end
  end

  defp vapid_configured? do
    details = Application.get_env(:web_push_encryption, :vapid_details, [])
    is_binary(details[:public_key]) and is_binary(details[:private_key])
  end
end
