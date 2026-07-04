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
    payload = build_payload(attrs)

    for recipient <- recipients,
        subscription <- subscriptions_for(recipient) do
      send_one(subscription, payload)
    end
  rescue
    error -> Logger.warning("web-push deliver raised, ignored: #{inspect(error)}")
  end

  # Chrome collapses notifications sharing a tag — tag by conversation so a burst shows once.
  defp build_payload(attrs) do
    %{body: body, message_type: message_type, content_type: content_type} =
      message_preview_fields(attrs.message_id)

    Jason.encode!(%{
      title: sender_name(attrs.sender_user_id),
      body: preview(body, message_type, content_type),
      tag: "conversation:#{attrs.conversation_id}",
      data: %{conversation_id: attrs.conversation_id, message_id: attrs.message_id}
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
