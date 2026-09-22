defmodule NotificationService.ApnsSender do
  @moduledoc """
  THE APPLE LEG. One sender for both Apple channels, because they are one app with one provider key
  and differ only in three values per request.

    * ALERT — topic `com.growblic.exway`, `apns-push-type: alert`. Message notifications.
    * VoIP  — topic `com.growblic.exway.voip`, `apns-push-type: voip`. Incoming calls, and ONLY
      incoming calls: iOS kills an app that takes a VoIP push and does not report a call to CallKit.

  Runs beside `FcmSender` and `PushSender` on the same fan-out, under the same suppression rules, and
  reads the same `PushContext` — so one account with an iPhone, an Android and a browser is told the
  same thing three times rather than three different things.

  ## Sandbox and production are per TOKEN, not per deployment

  A device token is valid at exactly one APNs host, and which one depends on how the APP was signed —
  a TestFlight build and an App Store build of one binary differ. The environment is stored on the
  token row (129) and chosen per send. A server-wide setting would have silently broken whichever
  half of the fleet it did not match, and the symptom (`BadDeviceToken`) names neither.

  ## Sealed chats carry a FETCH HINT, never plaintext

  For a sealed conversation the server holds ciphertext and nothing else, so there is no preview to
  send even if we wanted one. The push carries the ids, `mutable-content: 1`, and a hint telling the
  Notification Service Extension to fetch and decrypt locally. The visible body stays the generic
  string `PushContext.preview/3` already returns for a sealed message — the same one the Android and
  web legs show, so a sealed chat looks identical on every platform.

  `mutable-content: 1` is set on EVERY alert, not only sealed ones: the extension also attaches media
  thumbnails and rewrites the sender name, and an alert without it is delivered verbatim with no
  chance to run.

  ## Disabled cleanly

  No Apple key configured means `configured?/0` is false and every entry point returns `:ok` having
  done nothing — the same shape the FCM and VAPID legs use when their credentials are absent. A
  deployment without an Apple key behaves exactly as it did before this module existed.
  """

  require Logger

  alias NotificationService.PushContext
  alias NotificationService.Repo
  alias SharedInfra.Apns.ProviderToken

  @alert_topic "com.growblic.exway"
  @voip_topic "com.growblic.exway.voip"

  @production_host "api.push.apple.com"
  @sandbox_host "api.sandbox.push.apple.com"

  @doc "Fire-and-forget, mirroring the other two legs: a slow APNs never blocks the consumer."
  def push_message_created(attrs, recipients) do
    if configured?(), do: Task.start(fn -> deliver(attrs, recipients) end)
    :ok
  end

  @doc false
  # The SYNCHRONOUS core. Public so tests drive delivery deterministically rather than racing a task.
  def deliver(attrs, recipients) do
    case PushContext.message_context(attrs) do
      :no_preview -> :ok
      {:ok, context} -> deliver_to_recipients(context, attrs, recipients)
    end
  rescue
    error -> Logger.warning("apns deliver raised, ignored: #{inspect(error)}")
  end

  defp deliver_to_recipients(context, attrs, recipients) do
    Enum.each(recipients, fn recipient ->
      case skip_reason(attrs, recipient) do
        nil ->
          unread = PushContext.unread_count(attrs.conversation_id, recipient)
          badge = PushContext.total_unread_count(recipient)
          payload = message_payload(context, attrs, unread, badge)

          send_to_tokens(recipient, "alert", payload, @alert_topic, "alert")

        reason ->
          log_skipped(recipient, reason)
      end
    end)
  end

  # THE SAME GATES AS THE OTHER TWO LEGS, in the same order and fail-open for the same reason: a
  # Redis miss reads as "not present" and we SEND, because a redundant push beats a missed one.
  defp skip_reason(attrs, recipient) do
    cond do
      PushContext.muted?(attrs.conversation_id, recipient) -> "muted"
      presence().app_present?(recipient) -> "app_present"
      presence().present?(recipient, attrs.conversation_id) -> "viewing_conversation"
      true -> nil
    end
  end

  @doc """
  Fire-and-forget incoming-call push from the decoded `call.incoming` event (string keys) — the same
  entry point and the same shape the other two legs take.
  """
  def push_incoming_call(attrs) when is_map(attrs) do
    callee_id = attrs["callee_id"]

    if configured?() and is_binary(callee_id) and callee_id != "" do
      Task.start(fn -> deliver_call(attrs, callee_id) end)
    end

    :ok
  end

  @doc """
  Fire-and-forget STOP-RINGING push: the caller cancelled, or the server ring-timeout fired. A
  handset ringing off a VoIP push has no socket, so this is the only way CallKit stops before iOS
  gives up on the call.
  """
  def push_call_cancelled(attrs) when is_map(attrs) do
    callee_id = attrs["callee_id"]

    if configured?() and is_binary(callee_id) and callee_id != "" do
      Task.start(fn -> deliver_call_cancelled(attrs, callee_id) end)
    end

    :ok
  end

  @doc """
  An incoming call, as a VoIP push. No presence check and no mute check, unlike a message: a call is
  the one thing a muted, backgrounded phone still has to ring for, and CallKit is what rings it.
  """
  def deliver_call(attrs, callee_id) do
    if configured?() do
      send_to_tokens(callee_id, "voip", call_payload(attrs), @voip_topic, "voip")
    end

    :ok
  rescue
    error -> Logger.warning("apns call deliver raised, ignored: #{inspect(error)}")
  end

  @doc """
  The stop for a call that is no longer ringing. Also a VoIP push, because it has to reach the same
  place the ring did — an alert here would leave CallKit ringing a dead call while a banner said it
  had ended.
  """
  def deliver_call_cancelled(attrs, callee_id) do
    if configured?() do
      send_to_tokens(callee_id, "voip", call_cancelled_payload(attrs), @voip_topic, "voip")
    end

    :ok
  rescue
    error -> Logger.warning("apns cancel deliver raised, ignored: #{inspect(error)}")
  end

  @doc "Is an Apple provider key configured? The on/off switch for this whole leg."
  def configured?, do: ProviderToken.configured?()

  # ---- Payloads -------------------------------------------------------------------------------

  @doc false
  # PUBLIC so the payload contract is asserted with no network and no database. The data keys mirror
  # FcmSender.message_data/3 one for one — an iPhone and an Android must receive the same facts, or
  # the two clients drift into needing different server behaviour.
  def message_payload(context, attrs, unread, badge) do
    sealed? = context.preview == "New message" and sealed?(attrs)

    %{
      "aps" => %{
        "alert" => %{"title" => context.sender, "body" => context.preview},
        "badge" => badge,
        "sound" => "default",
        # ALWAYS 1. The extension rewrites the sender name, attaches thumbnails and decrypts sealed
        # bodies; without it the alert is delivered verbatim and the extension never runs.
        "mutable-content" => 1,
        # Groups the notification per conversation so iOS stacks a chat's messages together.
        "thread-id" => to_string(attrs.conversation_id)
      },
      "type" => "message",
      "conversation_id" => to_string(attrs.conversation_id),
      "message_id" => to_string(attrs.message_id),
      "sender_id" => to_string(attrs.sender_user_id),
      "sender_name" => context.sender,
      "unread_count" => unread
    }
    |> maybe_put("group_name", context.group_name)
    # THE FETCH HINT, and the only thing that distinguishes a sealed push. The body above is already
    # the generic string for a sealed message — the server has ciphertext and nothing else — so this
    # tells the extension there IS something to fetch and decrypt rather than leaving it to guess
    # from an absence.
    |> maybe_put("sealed", if(sealed?, do: true))
  end

  @doc false
  def call_payload(attrs) do
    caller =
      if is_binary(attrs["caller_name"]) and attrs["caller_name"] != "",
        do: attrs["caller_name"],
        else: "Someone"

    # NO `aps.alert`. A VoIP push is not a notification — CallKit draws the incoming-call UI from
    # this data, and an alert here would produce a banner beside the call screen.
    %{
      "aps" => %{},
      "type" => "call",
      "call_id" => to_string(attrs["call_id"]),
      "call_type" => to_string(attrs["call_type"] || "voice"),
      "caller_id" => to_string(attrs["caller_id"] || ""),
      "caller_name" => caller,
      # E2EE display hint (111), same as the Android leg: the ring UI shows the lock immediately.
      # The sealed key envelopes NEVER ride a push — the client fetches GET /api/v1/calls/:id.
      "e2ee" => attrs["e2ee"] == true
    }
    |> maybe_put("conversation_id", attrs["conversation_id"])
  end

  @doc false
  def call_cancelled_payload(attrs) do
    %{
      "aps" => %{},
      "type" => "call_cancelled",
      "call_id" => to_string(attrs["call_id"]),
      "reason" => to_string(attrs["reason"] || "cancelled")
    }
  end

  defp sealed?(attrs), do: Map.get(attrs, :message_type) == "sealed"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ---- Delivery -------------------------------------------------------------------------------

  defp send_to_tokens(user_id, kind, payload, topic, push_type) do
    case tokens_for(user_id, kind) do
      [] ->
        log_skipped(user_id, "no_#{kind}_tokens")

      targets ->
        Enum.each(targets, &send_one(&1, payload, topic, push_type))
    end
  end

  # Only iOS rows, only this channel. The partial index from 129 serves exactly this read.
  defp tokens_for(user_id, kind) do
    query =
      "SELECT token, environment FROM fcm_tokens " <>
        "WHERE user_id = $1::text::uuid AND platform = 'ios' AND kind = $2"

    case Repo.query(query, [user_id, kind]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [token, environment] -> %{token: token, environment: environment} end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp send_one(%{token: token, environment: environment}, payload, topic, push_type) do
    with {:ok, jwt} <- ProviderToken.fetch() do
      url = "https://#{host(environment)}/3/device/#{token}"

      headers = [
        {"authorization", "bearer " <> jwt},
        {"apns-topic", topic},
        {"apns-push-type", push_type},
        # 10 = deliver immediately. A VoIP push MUST be 10; Apple rejects 5 on that type.
        {"apns-priority", "10"},
        {"content-type", "application/json"}
      ]

      transport().post(url, headers, Jason.encode!(payload))
      |> handle_response(token, topic)
    else
      {:error, reason} ->
        Logger.warning("apns: no provider token (#{inspect(reason)}), push skipped")
    end
  end

  defp handle_response({:ok, 200, _body}, token, topic) do
    Logger.debug("apns: delivered topic=#{topic} token=#{redact(token)}")
    :ok
  end

  # 410 GONE, and 400 BadDeviceToken, are Apple saying the token is dead. Prune it — the same
  # contract the FCM leg follows for UNREGISTERED. Anything else is transient and the row stays.
  defp handle_response({:ok, status, body}, token, topic)
       when status in [400, 410] do
    if dead_token?(body) do
      %Postgrex.Result{num_rows: rows} =
        Repo.query!("DELETE FROM fcm_tokens WHERE token = $1", [token])

      Logger.info("apns: pruned a dead token topic=#{topic} rows=#{rows} token=#{redact(token)}")
    else
      Logger.warning("apns: rejected topic=#{topic} status=#{status} reason=#{reason(body)}")
    end

    :ok
  rescue
    _ -> :ok
  end

  defp handle_response({:ok, status, body}, _token, topic) do
    Logger.warning("apns: send failed topic=#{topic} status=#{status} reason=#{reason(body)}")
    :ok
  end

  defp handle_response({:error, reason}, _token, topic) do
    Logger.warning("apns: transport error topic=#{topic} reason=#{inspect(reason)}")
    :ok
  end

  defp dead_token?(body),
    do: reason(body) in ["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"]

  defp reason(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"reason" => reason}} -> reason
      _ -> "unknown"
    end
  end

  defp reason(_body), do: "unknown"

  defp host("sandbox"), do: @sandbox_host
  defp host(_environment), do: @production_host

  # Never log a whole device token — it is a delivery credential for that handset.
  defp redact(token) when is_binary(token) and byte_size(token) > 8,
    do: binary_part(token, 0, 8) <> "…"

  defp redact(_token), do: "…"

  defp log_skipped(user_id, reason),
    do: Logger.debug("apns: skipped user=#{user_id} reason=#{reason}")

  defp presence,
    do: Application.get_env(:notification_service, :presence, SharedInfra.PresenceMarker)

  defp transport,
    do: Application.get_env(:notification_service, :apns_transport, NotificationService.ApnsHttp)
end
