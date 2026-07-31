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

  alias NotificationService.PushContext
  alias NotificationService.Repo

  @doc "Fire-and-forget push fan-out for an applied message_created event."
  def push_message_created(attrs, recipients) do
    if vapid_configured?() and recipients != [] do
      Task.start(fn -> deliver(attrs, recipients) end)
    end

    :ok
  end

  @doc """
  Fire-and-forget incoming-call push for a BACKGROUNDED callee (Phase-1 calling). `attrs` is the decoded
  `call.incoming` event (string keys): "callee_id", "caller_name", "call_type", "call_id". Suppressed when
  the callee's app is foreground (they already got the in-app ring over the socket).
  """
  def push_incoming_call(attrs) when is_map(attrs) do
    callee_id = attrs["callee_id"]

    if vapid_configured?() and is_binary(callee_id) and callee_id != "" do
      Task.start(fn -> deliver_call(attrs, callee_id) end)
    end

    :ok
  end

  defp deliver_call(attrs, callee_id) do
    # Only for a backgrounded app — a foreground callee already got the `call:incoming` socket ring.
    unless SharedInfra.PresenceMarker.app_present?(callee_id) do
      payload = build_call_payload(attrs)
      for subscription <- subscriptions_for(callee_id), do: send_one(subscription, payload)
    end
  rescue
    error -> Logger.warning("call web-push deliver raised, ignored: #{inspect(error)}")
  end

  defp build_call_payload(attrs) do
    caller =
      if is_binary(attrs["caller_name"]) and attrs["caller_name"] != "",
        do: attrs["caller_name"],
        else: "Someone"

    label = if attrs["call_type"] == "video", do: "Video call", else: "Voice call"

    Jason.encode!(%{
      title: "Incoming call",
      body: "📞 #{caller} · #{label}",
      tag: "call:#{attrs["call_id"]}",
      data: %{type: "call", call_id: attrs["call_id"], call_type: attrs["call_type"]}
    })
  end

  defp deliver(attrs, recipients) do
    # Shared per-event context (one lookup each): the sender's name, the message preview, and — for a
    # GROUP — the group name. Per-recipient bits (mute, unread count) are resolved in the loop.
    context = message_context(attrs)

    for recipient <- recipients,
        not PushContext.muted?(attrs.conversation_id, recipient),
        # Presence-aware suppression. MAIN gate: the recipient's app is open/foreground ANYWHERE (any
        # chat or the list) → skip the web-push, the in-app toast covers them. Plus the narrower
        # "viewing THIS conversation" marker (harmless overlap). Both are short-TTL Redis markers the
        # realtime gateway maintains. FAIL-OPEN: any Redis miss/error → present?=false → we SEND (a
        # redundant push beats a missed one; a Redis hiccup never silently drops a push).
        not SharedInfra.PresenceMarker.app_present?(recipient),
        not SharedInfra.PresenceMarker.present?(recipient, attrs.conversation_id) do
      payload =
        build_payload(
          context,
          attrs,
          PushContext.unread_count(attrs.conversation_id, recipient),
          PushContext.total_unread_count(recipient)
        )

      for subscription <- subscriptions_for(recipient) do
        send_one(subscription, payload)
      end
    end
  rescue
    error -> Logger.warning("web-push deliver raised, ignored: #{inspect(error)}")
  end

  # The shared half (sender name, preview, group name) comes from PushContext — the SAME module the
  # FCM leg reads, which is what keeps a browser notification and an Android one saying the same
  # thing. Only the icon is web-only, so only the icon is added here.
  defp message_context(attrs) do
    attrs
    |> PushContext.message_context()
    |> Map.put(:icon, avatar_icon_url(attrs.sender_user_id))
  end

  # Sender's avatar as the notification icon. The gateway's avatar routes are AUTHENTICATED now, but a
  # service worker fetches a notification icon with no session — so we mint a narrow HMAC CAPABILITY TOKEN
  # (SharedInfra.AvatarToken) bound to (sender_user_id, sender's app_id, kind: avatar) and point at
  # `/api/v1/push/avatar/<token>`, the one public avatar path. The token grants read of ONLY this sender's
  # avatar image, in this app, for a bounded TTL (see AvatarToken); it can presign nothing else. Built from
  # PHX_HOST; nil in dev / non-real host, or if the sender's app can't be resolved → the SW uses the app
  # icon. A broken/absent avatar → the route 404s → the notification still shows with the app icon.
  defp avatar_icon_url(sender_user_id) do
    with host when is_binary(host) and host not in ["", "localhost"] <-
           System.get_env("PHX_HOST"),
         app_id when is_binary(app_id) <- sender_app_id(sender_user_id) do
      "https://#{host}/api/v1/push/avatar/#{SharedInfra.AvatarToken.sign(sender_user_id, app_id)}"
    else
      _ -> nil
    end
  end

  # The token binds the sender's app_id → the sender's own tenant (users_auth.app_id). One cheap indexed
  # lookup against the shared Postgres this service already reads (no extra service round trip).
  defp sender_app_id(sender_user_id) do
    case Repo.query("SELECT app_id::text FROM users_auth WHERE id = $1::text::uuid", [
           sender_user_id
         ]) do
      {:ok, %{rows: [[app_id]]}} when is_binary(app_id) -> app_id
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Per-recipient payload. DM → title = sender, body = preview. GROUP → "Sender in GroupName" as the
  # title (who + where), preview as the body. `unread` lets the SW collapse a burst into "N new
  # messages" (the tag already coalesces same-conversation notifications). `badgeCount` is the
  # recipient's TOTAL unread → the SW sets the PWA app-icon badge while closed (the app reconciles on
  # focus). `icon` is the sender's avatar-proxy URL → the SW uses it, falling back to the app icon.
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
        badgeCount: badge_count,
        icon: context.icon
      }
    })
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

  defp dump_uuid(value), do: PushContext.dump_uuid(value)

  defp vapid_configured? do
    details = Application.get_env(:web_push_encryption, :vapid_details, [])
    is_binary(details[:public_key]) and is_binary(details[:private_key])
  end
end
