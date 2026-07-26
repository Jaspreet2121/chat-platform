defmodule RealtimeGateway.ConversationChannel do
  use Phoenix.Channel

  alias RealtimeGateway.Limits
  alias RealtimeGateway.Presence
  alias RealtimeGateway.TopicAuthorization

  @impl true
  def join("conversation:" <> conversation_id = topic, _payload, socket) do
    with :ok <- Limits.check_join(socket),
         :ok <- TopicAuthorization.authorize_join(topic, socket) do
      socket = assign(socket, :conversation_id, conversation_id)
      send(self(), :after_join)

      {:ok,
       %{
         topic: topic,
         conversation_id: conversation_id,
         user_id: Map.get(socket.assigns, :current_user_id),
         status: "joined"
       }, socket}
    end
  end

  # Refresh the Redis presence marker well inside its TTL (45s) so it stays live while the user has the
  # conversation open — the notification service reads it to suppress web-push for the active viewer.
  @presence_heartbeat_ms 20_000

  @impl true
  def handle_info(:after_join, socket) do
    # Resolve ONCE at join whether this is a DIRECT conversation with a blocked peer (either direction), and
    # cache it in assigns. It gates the ephemeral typing/"viewing" signals below so a blocker never sees "X is
    # typing…" from someone they blocked. A mid-session block/unblock takes effect on the NEXT join — ephemeral
    # and low-stakes, not worth a per-keystroke recheck. Direct conversations only (false for groups/unknown).
    socket = assign(socket, :dm_blocked, resolve_dm_blocked(socket))
    # Resolve ONCE at join whether this socket's user may EMIT live read receipts here: the reader must have
    # read receipts ON, and for a DIRECT chat the PEER must too (the reciprocal rule — a reader who disabled
    # doesn't receive them either). Cached like dm_blocked; a mid-session toggle takes effect on the next join,
    # and the load-path read_by_count filter is always authoritative. Groups gate on the reader only.
    socket = assign(socket, :emit_read_receipts, resolve_emit_read_receipts(socket))

    with {:ok, user_id} <- current_user_id(socket),
         {:ok, _ref} <-
           Presence.track(socket, user_id, %{
             user_id: user_id,
             online_at: now_iso8601()
           }) do
      push(socket, "presence_state", Presence.list(socket))
      # Bridge presence to Redis for the (separate-node) notification service. Best-effort, non-
      # blocking — never slows or breaks presence tracking; the TTL self-heals a missed cleanup.
      write_presence_marker(user_id, socket.assigns.conversation_id)
      # Per-conversation "viewing now": tell the OTHER members of THIS conversation that the user opened it.
      # Conversation-scoped (broadcast on this conversation's topic only) → no cross-conversation leak, and
      # every recipient is already a member (they're joined to the topic). broadcast_from excludes the opener.
      broadcast_viewing(socket, user_id, true)
      Process.send_after(self(), :presence_heartbeat, @presence_heartbeat_ms)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info(:presence_heartbeat, socket) do
    with {:ok, user_id} <- current_user_id(socket) do
      write_presence_marker(user_id, socket.assigns.conversation_id)
    end

    Process.send_after(self(), :presence_heartbeat, @presence_heartbeat_ms)
    {:noreply, socket}
  end

  # On leave (tab close / navigate away / socket drop) clear the marker so pushes resume immediately;
  # the TTL is the fallback if this doesn't run. Phoenix auto-untracks Presence on process death.
  @impl true
  def terminate(_reason, socket) do
    with {:ok, user_id} <- current_user_id(socket),
         conversation_id when is_binary(conversation_id) <-
           Map.get(socket.assigns, :conversation_id) do
      clear_presence_marker(user_id, conversation_id)
      # Tell the remaining members the user stopped viewing. From terminate we can't broadcast_from (the
      # socket is going away), so broadcast on the conversation topic directly — the leaver's own channel is
      # dead, so a self-copy is harmless and the SDK dedups by (conversation, user) anyway. Suppressed for a
      # blocked DM peer, symmetric with the viewing(true) we withheld at join.
      unless Map.get(socket.assigns, :dm_blocked, false) do
        socket.endpoint.broadcast(
          "conversation:" <> conversation_id,
          "conversation_viewing",
          %{conversation_id: conversation_id, user_id: user_id, viewing: false}
        )
      end
    end

    :ok
  end

  # Redis I/O off the channel process so a slow/broken Redis never blocks realtime; fully fail-open.
  defp write_presence_marker(user_id, conversation_id)
       when is_binary(user_id) and is_binary(conversation_id) do
    Task.start(fn -> SharedInfra.PresenceMarker.mark(user_id, conversation_id) end)
    :ok
  end

  defp write_presence_marker(_user_id, _conversation_id), do: :ok

  defp clear_presence_marker(user_id, conversation_id) do
    Task.start(fn -> SharedInfra.PresenceMarker.clear(user_id, conversation_id) end)
    :ok
  end

  # "Viewing now" to the other members of this conversation (broadcast_from excludes the opener's socket).
  # Suppressed for a blocked DM peer (see broadcast_presence_signal/3).
  defp broadcast_viewing(socket, user_id, viewing) do
    broadcast_presence_signal(socket, "conversation_viewing", %{
      conversation_id: socket.assigns.conversation_id,
      user_id: user_id,
      viewing: viewing
    })

    :ok
  end

  # Ephemeral presence signal (typing / "viewing now") to the OTHER members. In a DIRECT conversation where the
  # peer is blocked (either direction), the blocker must not see "X is typing…"/viewing, so this no-ops — the
  # sender's own reply still returns {:ok}, only the fan-out is withheld. `dm_blocked` was resolved at join.
  defp broadcast_presence_signal(socket, event, payload) do
    unless Map.get(socket.assigns, :dm_blocked, false) do
      broadcast_from(socket, event, payload)
    end

    :ok
  end

  # Is this a DIRECT conversation whose peer is blocked (either direction)? Resolved once at join. Fail-open
  # (error → false = don't suppress) — a check glitch must not silently swallow typing for a legitimate chat.
  defp resolve_dm_blocked(socket) do
    with {:ok, user_id} <- current_user_id(socket),
         conversation_id when is_binary(conversation_id) <- Map.get(socket.assigns, :conversation_id),
         {:ok, result} <-
           SharedInfra.ConversationClient.direct_peer_blocked?(%{
             "conversation_id" => conversation_id,
             "user_id" => user_id
           }) do
      (Map.get(result, :blocked) || Map.get(result, "blocked")) == true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  # May this socket's user EMIT live read receipts here? Reader must have receipts ON (emit half); for a DIRECT
  # chat the peer must too (delivery half — a reader who disabled doesn't RECEIVE them). Group/unknown →
  # reader-only. R disabled / unresolved → false (never emit). An exception → true (fail-open; the load filter
  # still hides a disabled reader on reload).
  defp resolve_emit_read_receipts(socket) do
    with {:ok, me} <- current_user_id(socket),
         conversation_id when is_binary(conversation_id) <- Map.get(socket.assigns, :conversation_id),
         true <- read_receipts_enabled?(me) do
      case dm_peer(conversation_id, me) do
        peer when is_binary(peer) -> read_receipts_enabled?(peer)
        _ -> true
      end
    else
      _ -> false
    end
  rescue
    _ -> true
  end

  # The OTHER active participant of a DIRECT conversation (nil for a group / unknown), via the same
  # get_conversation the peer-contact path uses. Resolved once at join, off the read-mark hot path.
  defp dm_peer(conversation_id, me) do
    case SharedInfra.ConversationClient.get_conversation(%{
           "conversation_id" => conversation_id,
           "user_id" => me
         }) do
      {:ok, conversation} ->
        if (Map.get(conversation, :type) || Map.get(conversation, "type")) == "direct" do
          (Map.get(conversation, :participants) || Map.get(conversation, "participants") || [])
          |> Enum.map(&(Map.get(&1, :user_id) || Map.get(&1, "user_id")))
          |> Enum.find(&(is_binary(&1) and &1 != me))
        else
          nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  # A user's read_receipts_enabled (default TRUE for no row / persistence off / a read glitch — fail-open).
  defp read_receipts_enabled?(user_id) when is_binary(user_id) and user_id != "" do
    case SharedInfra.UserClient.get_privacy(%{"user_id" => user_id}) do
      {:ok, privacy} ->
        # Map.get with a default (NOT `||`) so `false` reads as false, not "absent". Enabled unless explicit false.
        Map.get(privacy, :read_receipts_enabled, Map.get(privacy, "read_receipts_enabled")) != false

      _ ->
        true
    end
  rescue
    _ -> true
  end

  defp read_receipts_enabled?(_user_id), do: true

  # EPHEMERAL bucket (typing, receipts, live-location): over the limit → dropped SILENTLY ({:noreply}).
  # WRITE bucket (message create/update/delete, reactions): over the limit → an error reply carrying
  # retry_after, the socket STAYS alive (the SDK backs off). See RealtimeGateway.Limits.

  @impl true
  def handle_in("typing_started", payload, socket) do
    with :ok <- Limits.check_ephemeral(socket) do
      reply = conversation_reply("typing_started", payload, socket)
      broadcast_presence_signal(socket, "presence_updated", Map.put(reply, :typing, true))

      {:reply, {:ok, reply}, socket}
    end
  end

  def handle_in("typing:start", _payload, socket) do
    with :ok <- Limits.check_ephemeral(socket) do
      typing_event("typing_started", socket)
    end
  end

  def handle_in("typing:stop", _payload, socket) do
    with :ok <- Limits.check_ephemeral(socket) do
      typing_event("typing_stopped", socket)
    end
  end

  def handle_in("typing_stopped", payload, socket) do
    with :ok <- Limits.check_ephemeral(socket) do
      reply = conversation_reply("typing_stopped", payload, socket)
      broadcast_presence_signal(socket, "presence_updated", Map.put(reply, :typing, false))

      {:reply, {:ok, reply}, socket}
    end
  end

  def handle_in("message_read", payload, socket) do
    with :ok <- Limits.check_ephemeral(socket) do
      reply = conversation_reply("message_read", payload, socket)

      # Snapshot the reader's unread BEFORE the write: this handler fires once PER MESSAGE, and re-marking an
      # already-read message changes nothing. Without this, a client re-reading an open thread would spray an
      # identical inbox row on every frame. nil (unknown) simply means "don't skip".
      unread_before = reader_unread_before(socket)

      # Persist FIRST so the receipt survives a reload (and drives the reader's OWN unread count), THEN maybe
      # broadcast the live tick. The read is ALWAYS persisted; the live tick is emitted only if reciprocity
      # permits (resolved at join). A suppressed live tick and the load-path read_by_count filter agree, so a
      # reader who disabled receipts is invisible both live and on reload. Delivered ticks are never gated.
      persist_receipt(:read, payload, socket)

      if Map.get(socket.assigns, :emit_read_receipts, true) do
        broadcast_from(socket, "receipt_updated", Map.put(reply, :receipt_type, "read"))
      end

      notify_inbox_read(socket, unread_before)

      {:reply, {:ok, reply}, socket}
    end
  end

  def handle_in("message_delivered", payload, socket) do
    with :ok <- Limits.check_ephemeral(socket) do
      reply = conversation_reply("message_delivered", payload, socket)
      persist_receipt(:delivered, payload, socket)
      broadcast_from(socket, "receipt_updated", Map.put(reply, :receipt_type, "delivered"))

      {:reply, {:ok, reply}, socket}
    end
  end

  def handle_in("message:create", payload, socket) do
    with :ok <- Limits.check_write(socket) do
      create_message(payload, socket)
    end
  end

  def handle_in("message:new", payload, socket) do
    with :ok <- Limits.check_write(socket) do
      create_message(payload, socket)
    end
  end

  def handle_in("message:update", payload, socket) do
    with :ok <- Limits.check_write(socket) do
      update_message(payload, socket)
    end
  end

  def handle_in("message:delete", payload, socket) do
    with :ok <- Limits.check_write(socket) do
      delete_message(payload, socket)
    end
  end

  def handle_in("reaction:set", payload, socket) do
    with :ok <- Limits.check_write(socket) do
      set_reaction(payload, socket)
    end
  end

  def handle_in("reaction:remove", payload, socket) do
    with :ok <- Limits.check_write(socket) do
      remove_reaction(payload, socket)
    end
  end

  def handle_in("live_location:update", payload, socket) do
    with :ok <- Limits.check_ephemeral(socket) do
      update_live_location(payload, socket)
    end
  end

  defp set_reaction(payload, socket) do
    with :ok <- validate_reaction_set_payload(payload),
         {:ok, user_id} <- current_user_id(socket),
         {:ok, response} <-
           SharedInfra.MessageClient.add_reaction(%{
             "conversation_id" => socket.assigns.conversation_id,
             "message_id" => payload["message_id"],
             "user_id" => user_id,
             "emoji" => payload["emoji"]
           }) do
      broadcast_reaction(socket, response)
      {:reply, {:ok, response}, socket}
    else
      {:error, :missing_user} -> unauthorized_reply(socket)
      {:error, :message_unavailable} -> unavailable_reply(socket)
      _ -> invalid_event_reply(socket)
    end
  end

  defp remove_reaction(payload, socket) do
    with :ok <- validate_reaction_remove_payload(payload),
         {:ok, user_id} <- current_user_id(socket),
         {:ok, response} <-
           SharedInfra.MessageClient.remove_reaction(%{
             "conversation_id" => socket.assigns.conversation_id,
             "message_id" => payload["message_id"],
             "user_id" => user_id
           }) do
      broadcast_reaction(socket, response)
      {:reply, {:ok, response}, socket}
    else
      {:error, :missing_user} -> unauthorized_reply(socket)
      {:error, :message_unavailable} -> unavailable_reply(socket)
      _ -> invalid_event_reply(socket)
    end
  end

  # Broadcast the authoritative per-message aggregate to the OTHER tabs. The acting client patches
  # itself from the {:ok, response} reply, so broadcast_from (sender-excluded) avoids a double-apply.
  defp broadcast_reaction(socket, response) do
    broadcast_from(socket, "reaction_updated", %{
      message_id: Map.get(response, :message_id) || Map.get(response, "message_id"),
      reactions: Map.get(response, :reactions) || Map.get(response, "reactions") || []
    })
  end

  defp create_message(payload, socket) do
    with :ok <- validate_message_payload(payload),
         {:ok, sender_user_id} <- current_user_id(socket),
         # SERVER-SIDE only-admins-can-send enforcement on the realtime path too — a plain member in a
         # locked group can't send even by pushing the socket event directly. This SAME call also carries the
         # BLOCK disposition: for a DIRECT chat the recipient has blocked, it returns delivery: "drop".
         {:ok, disposition} <-
           SharedInfra.ConversationClient.authorize_send(%{
             "conversation_id" => socket.assigns.conversation_id,
             "user_id" => sender_user_id
           }),
         dropped? = dropped?(disposition),
         {:ok, response} <-
           payload
           |> Map.put("conversation_id", socket.assigns.conversation_id)
           |> Map.put("sender_user_id", sender_user_id)
           |> put_delivery(dropped?)
           |> SharedInfra.MessageClient.create_message() do
      # A DROPPED (blocked) message returns a canonical single-tick ack to the SENDER but fans out to NOBODY —
      # the blocker never receives it (nothing persisted, nothing broadcast). Everything below is the delivery
      # the blocker must not get, so it is skipped entirely.
      unless dropped? do
        broadcast_from(socket, "message_created", response)
        notify_user_topics(socket, sender_user_id, response)
        # Live INBOX row (distinct from the message fan-out above: that wakes an OPEN thread, this wakes every
        # participant's conversation LIST). Per-user unread, fire-and-forget, shared with the HTTP paths.
        SharedInfra.ConversationBroadcast.broadcast_updated(
          socket.endpoint,
          socket.assigns.conversation_id,
          sender_user_id,
          :message
        )
      end

      {:reply, {:ok, response}, socket}
    else
      {:error, :missing_user} ->
        {:reply,
         {:error,
          %{code: "realtime.unauthorized", message: "Missing or invalid socket authentication"}},
         socket}

      {:error, :only_admins_can_send} ->
        {:reply,
         {:error,
          %{code: "group.only_admins_can_send", message: "Only admins can send messages"}}, socket}

      {:error, :message_unavailable} ->
        unavailable_reply(socket)

      _ ->
        {:reply,
         {:error, %{code: "realtime.invalid_event", message: "Message event payload is invalid"}},
         socket}
    end
  end

  # IN-APP notification fan-out: mirror message_created onto each OTHER participant's `user:<id>`
  # topic (identity-pinned channel that already exists) so clients get live unread badges/toasts for
  # conversations they DON'T have open — joining every conversation channel instead would falsely mark
  # them present ("Active now") everywhere. Fire-and-forget: never blocks or fails the send. This is
  # the existing websocket, NOT push infra (no service worker / web-push).
  defp notify_user_topics(socket, sender_user_id, response) do
    endpoint = socket.endpoint
    conversation_id = socket.assigns.conversation_id

    Task.start(fn ->
      case SharedInfra.ConversationClient.get_conversation(%{
             "conversation_id" => conversation_id,
             "user_id" => sender_user_id
           }) do
        {:ok, conversation} ->
          (Map.get(conversation, :participants) || Map.get(conversation, "participants") || [])
          |> Enum.map(fn p -> Map.get(p, :user_id) || Map.get(p, "user_id") end)
          |> Enum.reject(&(&1 in [nil, sender_user_id]))
          |> Enum.each(fn user_id ->
            endpoint.broadcast("user:" <> user_id, "message_created", response)
          end)

        _ ->
          :ok
      end
    end)

    :ok
  rescue
    _ -> :ok
  end

  # The send gate's disposition: delivery: "drop" means the recipient blocked the sender (DIRECT chat).
  defp dropped?(disposition) when is_map(disposition),
    do: Map.get(disposition, :delivery) == "drop" or Map.get(disposition, "delivery") == "drop"

  defp dropped?(_disposition), do: false

  # SERVER-controlled flag: set it on a drop, and STRIP any client-injected value on the allow path (a client
  # must never be able to force a synthesize).
  defp put_delivery(attrs, true), do: Map.put(attrs, "delivery_disposition", "drop")
  defp put_delivery(attrs, false), do: Map.delete(attrs, "delivery_disposition")

  defp update_message(payload, socket) do
    with :ok <- validate_update_payload(payload),
         {:ok, actor_user_id} <- current_user_id(socket),
         {:ok, response} <-
           payload
           |> Map.put("conversation_id", socket.assigns.conversation_id)
           |> Map.put("actor_user_id", actor_user_id)
           |> SharedInfra.MessageClient.update_message() do
      broadcast_from(socket, "message_updated", response)
      {:reply, {:ok, response}, socket}
    else
      {:error, :missing_user} -> unauthorized_reply(socket)
      {:error, :message_forbidden} -> forbidden_reply(socket)
      # A soft-deleted message accepts no update (an edit would resurrect the tombstone). Distinct error
      # reply; the socket stays connected, exactly like every other rejected event.
      {:error, :message_deleted} -> deleted_reply(socket)
      {:error, :message_unavailable} -> unavailable_reply(socket)
      _ -> invalid_event_reply(socket)
    end
  end

  # Live location: the sharer streams throttled position updates. We persist the latest position to the
  # message metadata (so late joiners / refetch see it + the live/ended flag) via the author-gated
  # update path, then broadcast a lightweight update to the OTHER participants (their bubble moves the
  # marker). NOT sent to user topics — it's high-frequency and only relevant to those viewing the chat.
  defp update_live_location(payload, socket) do
    with :ok <- validate_live_location_payload(payload),
         {:ok, actor_user_id} <- current_user_id(socket),
         {:ok, _response} <-
           SharedInfra.MessageClient.update_message(%{
             "conversation_id" => socket.assigns.conversation_id,
             "message_id" => payload["message_id"],
             "actor_user_id" => actor_user_id,
             "metadata_patch" => live_location_patch(payload)
           }) do
      broadcast_from(socket, "live_location_updated", %{
        message_id: payload["message_id"],
        lat: payload["lat"],
        lng: payload["lng"],
        accuracy: Map.get(payload, "accuracy"),
        at: Map.get(payload, "at") || now_iso8601(),
        live: live_flag(payload)
      })

      {:reply, {:ok, %{status: "ok"}}, socket}
    else
      {:error, :missing_user} -> unauthorized_reply(socket)
      {:error, :message_forbidden} -> forbidden_reply(socket)
      # A live-location patch on a soft-deleted message is refused too — the SAME author gate
      # (fetch_own_message) covers :metadata updates, not just body edits.
      {:error, :message_deleted} -> deleted_reply(socket)
      {:error, :message_unavailable} -> unavailable_reply(socket)
      _ -> invalid_event_reply(socket)
    end
  end

  # Metadata patch merged into the live_location message. All values stringified downstream; here we set
  # the latest position, a timestamp, and the live/ended flag (stop sends live:false).
  defp live_location_patch(payload) do
    ended? = live_flag(payload) == false

    %{
      "lat" => to_string(payload["lat"]),
      "lng" => to_string(payload["lng"]),
      "accuracy" => to_string(Map.get(payload, "accuracy", "")),
      "live_at" => Map.get(payload, "at") || now_iso8601(),
      "live" => if(ended?, do: "false", else: "true")
    }
    |> then(fn m -> if ended?, do: Map.put(m, "ended_at", now_iso8601()), else: m end)
  end

  # A live-location update is "ended" when the client explicitly sends live=false; otherwise it's live.
  defp live_flag(%{"live" => false}), do: false
  defp live_flag(%{"live" => "false"}), do: false
  defp live_flag(_), do: true

  defp validate_live_location_payload(%{"message_id" => id, "lat" => lat, "lng" => lng})
       when is_binary(id) and id != "" and (is_number(lat) or is_binary(lat)) and
              (is_number(lng) or is_binary(lng)),
       do: :ok

  defp validate_live_location_payload(_payload), do: {:error, :invalid_event}

  defp delete_message(payload, socket) do
    with :ok <- validate_delete_payload(payload),
         {:ok, actor_user_id} <- current_user_id(socket),
         {:ok, response} <-
           payload
           |> Map.put("conversation_id", socket.assigns.conversation_id)
           |> Map.put("actor_user_id", actor_user_id)
           |> SharedInfra.MessageClient.delete_message() do
      broadcast_from(socket, "message_deleted", response)
      {:reply, {:ok, response}, socket}
    else
      {:error, :missing_user} -> unauthorized_reply(socket)
      {:error, :message_forbidden} -> forbidden_reply(socket)
      {:error, :message_unavailable} -> unavailable_reply(socket)
      _ -> invalid_event_reply(socket)
    end
  end

  defp unauthorized_reply(socket) do
    {:reply,
     {:error,
      %{code: "realtime.unauthorized", message: "Missing or invalid socket authentication"}},
     socket}
  end

  defp forbidden_reply(socket) do
    {:reply,
     {:error, %{code: "realtime.forbidden", message: "You can only modify your own messages"}},
     socket}
  end

  # A soft-deleted message accepts no update (body edit OR live-location metadata patch) — editing it would
  # resurrect the tombstone. The socket stays alive; the client just gets a rejected reply.
  defp deleted_reply(socket) do
    {:reply, {:error, %{code: "realtime.message_deleted", message: "This message was deleted"}}, socket}
  end

  defp invalid_event_reply(socket) do
    {:reply,
     {:error, %{code: "realtime.invalid_event", message: "Message event payload is invalid"}},
     socket}
  end

  # message-service unreachable over the network (HTTP adapter): reject with a distinct signal.
  defp unavailable_reply(socket) do
    {:reply, {:error, %{code: "realtime.unavailable", message: "Message service is unavailable"}},
     socket}
  end

  defp typing_event(event, socket) do
    with {:ok, user_id} <- current_user_id(socket) do
      payload = %{
        conversation_id: socket.assigns.conversation_id,
        user_id: user_id,
        occurred_at: now_iso8601()
      }

      broadcast_presence_signal(socket, event, payload)
      {:reply, {:ok, Map.put(payload, :event, event)}, socket}
    else
      {:error, :missing_user} ->
        {:reply,
         {:error,
          %{code: "realtime.unauthorized", message: "Missing or invalid socket authentication"}},
         socket}
    end
  end

  defp conversation_reply(event, payload, socket) do
    %{
      event: event,
      conversation_id: socket.assigns.conversation_id,
      user_id: Map.get(socket.assigns, :current_user_id),
      payload: payload,
      status: "accepted"
    }
  end

  # Durably record a read/delivered receipt for the marking user via the message client (in-process or
  # HTTP). Best-effort: persistence is gated by MESSAGE_DB_BACKED on the message side, so plain
  # `mix test` (persistence off) takes the placeholder path with no DB. Never blocks the live broadcast.
  # The reader's unread count BEFORE the receipt is written (nil when the user can't be resolved → "don't
  # skip"). See notify_inbox_read/2.
  defp reader_unread_before(socket) do
    case current_user_id(socket) do
      {:ok, user_id} ->
        SharedInfra.ConversationBroadcast.unread_before(socket.assigns.conversation_id, user_id)

      _ ->
        nil
    end
  end

  # Live INBOX after a read: only the READER's badge changed, so fan out to them alone rather than waking all
  # N participants on every read — and only when the count ACTUALLY moved (re-reading an already-read message
  # is a no-op that must not re-broadcast an identical row).
  defp notify_inbox_read(socket, unread_before) do
    case current_user_id(socket) do
      {:ok, user_id} ->
        SharedInfra.ConversationBroadcast.broadcast_updated(
          socket.endpoint,
          socket.assigns.conversation_id,
          user_id,
          :receipt,
          only: [user_id],
          skip_if_unread: unread_before
        )

      _ ->
        :ok
    end
  end

  defp persist_receipt(status, payload, socket) do
    with {:ok, user_id} <- current_user_id(socket),
         message_id when is_binary(message_id) and message_id != "" <-
           Map.get(payload, "message_id") do
      attrs = %{
        "conversation_id" => socket.assigns.conversation_id,
        "message_id" => message_id,
        "user_id" => user_id
      }

      case status do
        :read -> SharedInfra.MessageClient.mark_read(attrs)
        :delivered -> SharedInfra.MessageClient.mark_delivered(attrs)
      end
    end

    :ok
  end

  defp validate_message_payload(%{"message_type" => "text", "body" => body})
       when is_binary(body) and body != "" do
    :ok
  end

  defp validate_message_payload(%{"message_type" => "text"}), do: {:error, :invalid_event}

  defp validate_message_payload(%{"message_type" => "media", "media_id" => media_id})
       when is_binary(media_id) and media_id != "" do
    :ok
  end

  defp validate_message_payload(%{"message_type" => "media"}), do: {:error, :invalid_event}

  defp validate_message_payload(%{"message_type" => message_type})
       when is_binary(message_type) and message_type != "" do
    :ok
  end

  defp validate_message_payload(_payload), do: {:error, :invalid_event}

  defp validate_update_payload(%{"message_id" => message_id, "body" => body})
       when is_binary(message_id) and message_id != "" and is_binary(body) and body != "" do
    :ok
  end

  defp validate_update_payload(_payload), do: {:error, :invalid_event}

  defp validate_delete_payload(%{"message_id" => message_id})
       when is_binary(message_id) and message_id != "" do
    :ok
  end

  defp validate_delete_payload(_payload), do: {:error, :invalid_event}

  defp validate_reaction_set_payload(%{"message_id" => message_id, "emoji" => emoji})
       when is_binary(message_id) and message_id != "" and is_binary(emoji) and emoji != "" do
    :ok
  end

  defp validate_reaction_set_payload(_payload), do: {:error, :invalid_event}

  defp validate_reaction_remove_payload(%{"message_id" => message_id})
       when is_binary(message_id) and message_id != "" do
    :ok
  end

  defp validate_reaction_remove_payload(_payload), do: {:error, :invalid_event}

  defp current_user_id(socket) do
    user_id = Map.get(socket.assigns, :user_id) || Map.get(socket.assigns, :current_user_id)

    case user_id do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_user}
    end
  end

  defp now_iso8601 do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
