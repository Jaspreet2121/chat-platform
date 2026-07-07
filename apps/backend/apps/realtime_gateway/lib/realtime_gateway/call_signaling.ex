defmodule RealtimeGateway.CallSignaling do
  @moduledoc """
  Phase-1 call RING signaling over the `user:<id>` channel — the "WhatsApp ring" control plane. LiveKit
  handles the media; here we only invite/accept/reject/cancel/hangup and fan the events to the other
  party's `user:<id>` topic (mirroring the conversation channel's `notify_user_topics`).

  Flow: caller pushes `call:invite` on their OWN `user:<id>` → we persist a ringing call (CallStore) and
  broadcast `call:incoming` to the callee → callee `call:accept`/`call:reject` → we transition + broadcast
  back. Cancel (caller, pre-answer) / hangup (either) / a server-side ring timeout all transition + notify.

  AUTH: invite is implicitly self (the channel is identity-pinned to current_user_id). accept/reject are
  callee-only, cancel is caller-only, hangup is either party — validated against the persisted call row.

  A best-effort incoming-call web-push is emitted for a backgrounded callee (see `emit_incoming_push/4`).

  Phase 3 adds a SEPARATE group event set (`call:group_invite`/`group_join`/`group_decline`/`group_leave`)
  that fans out to N conversation members over their `user:<id>` topics (`call:group_incoming`,
  `call:participant_joined`/`declined`/`left`, `call:group_ended`). Membership/permission live in CallStore
  (A1); the 1-on-1 handlers above are untouched.
  """

  require Logger

  alias SharedInfra.ConversationClient

  @ring_timeout_ms 35_000
  @call_events_topic "call.events.v1"

  @doc "Dispatch a `call:*` event from the user channel. Returns a `{:reply, reply, socket}` tuple."
  # 1-on-1 (Phase 1/2) — UNCHANGED.
  def handle_event("call:invite", payload, socket), do: invite(payload, socket)
  def handle_event("call:accept", payload, socket), do: accept(payload, socket)
  def handle_event("call:reject", payload, socket), do: reject(payload, socket)
  def handle_event("call:cancel", payload, socket), do: cancel(payload, socket)
  def handle_event("call:hangup", payload, socket), do: hangup(payload, socket)
  # Group (Phase 3) — a SEPARATE event set; distinct handlers, no callee_id.
  def handle_event("call:group_invite", payload, socket), do: group_invite(payload, socket)
  def handle_event("call:group_join", payload, socket), do: group_join(payload, socket)
  def handle_event("call:group_decline", payload, socket), do: group_decline(payload, socket)
  def handle_event("call:group_leave", payload, socket), do: group_leave(payload, socket)
  def handle_event("call:group_add", payload, socket), do: group_add(payload, socket)
  def handle_event(_event, _payload, socket), do: reply_error(socket, "call.invalid_event")

  # --- invite: caller → create ringing call → ring the callee ------------------------------------
  def invite(%{"callee_id" => callee_id, "type" => type} = payload, socket)
      when is_binary(callee_id) and callee_id != "" and type in ["voice", "video"] do
    caller_id = current_user(socket)

    cond do
      callee_id == caller_id ->
        reply_error(socket, "call.invalid_callee")

      true ->
        case ConversationClient.create_call(%{
               "caller_id" => caller_id,
               "callee_id" => callee_id,
               "type" => type,
               "conversation_id" => payload["conversation_id"]
             }) do
          {:ok, call} ->
            call_id = cget(call, :id)
            room = cget(call, :room_name)
            caller_name = resolve_name(caller_id)

            broadcast(socket, callee_id, "call:incoming", %{
              call_id: call_id,
              room: room,
              caller_id: caller_id,
              caller_name: caller_name,
              type: type,
              conversation_id: cget(call, :conversation_id)
            })

            emit_incoming_push(callee_id, caller_name, type, call_id)

            # Server-side ring timeout (this = the caller's channel process). On fire we re-check status,
            # so accept/reject/cancel/hangup transitioning first makes it a no-op — no cross-process cancel.
            Process.send_after(self(), {:call_ring_timeout, call_id}, @ring_timeout_ms)

            {:reply, {:ok, %{call_id: call_id, room: room}}, socket}

          {:error, _reason} ->
            reply_error(socket, "call.unavailable")
        end
    end
  end

  def invite(_payload, socket), do: reply_error(socket, "call.invalid_request")

  # --- accept / reject (callee only) -------------------------------------------------------------
  defp accept(%{"call_id" => call_id}, socket) do
    with_call(call_id, socket, [:callee], fn call, _role ->
      case ConversationClient.mark_call_answered(%{"call_id" => call_id}) do
        {:ok, _} ->
          broadcast(socket, cget(call, :caller_id), "call:accepted", %{
            call_id: call_id,
            room: cget(call, :room_name)
          })

          {:reply, {:ok, %{call_id: call_id, room: cget(call, :room_name)}}, socket}

        {:error, _} ->
          reply_error(socket, "call.unavailable")
      end
    end)
  end

  defp accept(_payload, socket), do: reply_error(socket, "call.invalid_request")

  defp reject(%{"call_id" => call_id}, socket) do
    with_call(call_id, socket, [:callee], fn call, _role ->
      _ = ConversationClient.mark_call_declined(%{"call_id" => call_id})
      broadcast(socket, cget(call, :caller_id), "call:rejected", %{call_id: call_id})
      {:reply, {:ok, %{call_id: call_id}}, socket}
    end)
  end

  defp reject(_payload, socket), do: reply_error(socket, "call.invalid_request")

  # --- cancel (caller only, pre-answer) ----------------------------------------------------------
  defp cancel(%{"call_id" => call_id}, socket) do
    with_call(call_id, socket, [:caller], fn call, _role ->
      _ = ConversationClient.mark_call_missed(%{"call_id" => call_id})
      write_missed_message(call, socket)
      broadcast(socket, cget(call, :callee_id), "call:cancelled", %{call_id: call_id})
      {:reply, {:ok, %{call_id: call_id}}, socket}
    end)
  end

  defp cancel(_payload, socket), do: reply_error(socket, "call.invalid_request")

  # --- hangup (either party) → notify the OTHER party --------------------------------------------
  defp hangup(%{"call_id" => call_id}, socket) do
    with_call(call_id, socket, [:caller, :callee], fn call, role ->
      _ = ConversationClient.mark_call_ended(%{"call_id" => call_id})
      other = if role == :caller, do: cget(call, :callee_id), else: cget(call, :caller_id)
      broadcast(socket, other, "call:ended", %{call_id: call_id})
      {:reply, {:ok, %{call_id: call_id}}, socket}
    end)
  end

  defp hangup(_payload, socket), do: reply_error(socket, "call.invalid_request")

  @doc """
  Ring timeout (fired from the caller's channel via `handle_info`). Only marks missed if the call is STILL
  ringing (accept/reject/cancel/hangup already moved it → no-op), then broadcasts `call:missed` to both.
  """
  def ring_timeout(call_id, socket) when is_binary(call_id) do
    case ConversationClient.get_call(%{"call_id" => call_id}) do
      {:ok, call} ->
        if cget(call, :status) == "ringing" do
          _ = ConversationClient.mark_call_missed(%{"call_id" => call_id})
          write_missed_message(call, socket)
          broadcast(socket, cget(call, :caller_id), "call:missed", %{call_id: call_id})
          broadcast(socket, cget(call, :callee_id), "call:missed", %{call_id: call_id})
        end

      _ ->
        :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  # ============================================================================================
  # Group calling (Phase 3). SEPARATE event set — no callee_id; membership + permission live in
  # CallStore (A1). Fan-out reuses the same `broadcast/4` over each member's user:<id> topic. The acting
  # user is ALWAYS current_user(socket) — a user_id in the payload is never trusted.
  # ============================================================================================

  # call:group_invite %{"conversation_id","type"} — initiator starts a group call → ring every other member.
  defp group_invite(%{"conversation_id" => cid, "type" => type}, socket)
       when is_binary(cid) and cid != "" and type in ["voice", "video"] do
    initiator = current_user(socket)

    case ConversationClient.create_group_call(%{
           "initiator_id" => initiator,
           "conversation_id" => cid,
           "type" => type
         }) do
      {:ok, result} ->
        call = cget(result, :call)
        parts = cget(result, :participants) || []
        others = cget(result, :member_ids) || []
        call_id = cget(call, :id)
        room = cget(call, :room_name)
        caller_name = resolve_name(initiator)

        Enum.each(others, fn member_id ->
          broadcast(socket, member_id, "call:group_incoming", %{
            call_id: call_id,
            room: room,
            conversation_id: cid,
            type: type,
            caller_id: initiator,
            caller_name: caller_name,
            participants: parts
          })
        end)

        # Server-side group ring timeout (this = the initiator's channel). On fire we mark still-invited
        # members missed; joins first make it a no-op (idempotent) — mirrors the 1-on-1 timer.
        Process.send_after(self(), {:group_ring_timeout, call_id}, @ring_timeout_ms)

        {:reply, {:ok, %{call_id: call_id, room: room, participants: parts}}, socket}

      {:error, :call_start_forbidden} ->
        reply_error(socket, "call.start_forbidden")

      {:error, :not_a_member} ->
        reply_error(socket, "call.forbidden")

      {:error, _reason} ->
        reply_error(socket, "call.unavailable")
    end
  end

  defp group_invite(_payload, socket), do: reply_error(socket, "call.invalid_request")

  # call:group_join %{"call_id"} — accept OR late-join. Notifies the other participants.
  defp group_join(%{"call_id" => call_id}, socket) when is_binary(call_id) and call_id != "" do
    me = current_user(socket)

    case ConversationClient.join_group_call(%{"call_id" => call_id, "user_id" => me}) do
      {:ok, result} ->
        room = result |> cget(:call) |> cget(:room_name)
        joined_at = result |> cget(:participant) |> cget(:joined_at)

        broadcast_group(socket, call_id, me, ["invited", "joined"], "call:participant_joined", %{
          call_id: call_id,
          user_id: me,
          joined_at: joined_at
        })

        {:reply, {:ok, %{call_id: call_id, room: room}}, socket}

      {:error, :not_a_member} ->
        reply_error(socket, "call.forbidden")

      {:error, :call_not_found} ->
        reply_error(socket, "call.not_found")

      {:error, _reason} ->
        reply_error(socket, "call.unavailable")
    end
  end

  defp group_join(_payload, socket), do: reply_error(socket, "call.invalid_request")

  # call:group_decline %{"call_id"} — one member declines. Notifies others; ends the call if it closed.
  defp group_decline(%{"call_id" => call_id}, socket) when is_binary(call_id) and call_id != "" do
    me = current_user(socket)

    case ConversationClient.decline_group_call(%{"call_id" => call_id, "user_id" => me}) do
      {:ok, result} ->
        broadcast_group(socket, call_id, me, ["invited", "joined"], "call:participant_declined", %{
          call_id: call_id,
          user_id: me
        })

        maybe_broadcast_group_ended(socket, call_id, cget(result, :call))
        {:reply, {:ok, %{call_id: call_id}}, socket}

      {:error, :call_not_found} ->
        reply_error(socket, "call.not_found")

      {:error, _reason} ->
        reply_error(socket, "call.unavailable")
    end
  end

  defp group_decline(_payload, socket), do: reply_error(socket, "call.invalid_request")

  # call:group_leave %{"call_id"} — a participant leaves. Notifies the rest; ends the call if nobody remains.
  defp group_leave(%{"call_id" => call_id}, socket) when is_binary(call_id) and call_id != "" do
    me = current_user(socket)

    case ConversationClient.leave_group_call(%{"call_id" => call_id, "user_id" => me}) do
      {:ok, result} ->
        broadcast_group(socket, call_id, me, ["invited", "joined"], "call:participant_left", %{
          call_id: call_id,
          user_id: me
        })

        maybe_broadcast_group_ended(socket, call_id, cget(result, :call))
        {:reply, {:ok, %{call_id: call_id}}, socket}

      {:error, :call_not_found} ->
        reply_error(socket, "call.not_found")

      {:error, _reason} ->
        reply_error(socket, "call.unavailable")
    end
  end

  defp group_leave(_payload, socket), do: reply_error(socket, "call.invalid_request")

  # call:group_add %{"call_id","user_id"} (existing member) OR %{"call_id","phone"} (outside person) — add
  # someone to a LIVE group call and ring them in. Actor = current_user (never trusted from payload); the
  # permission to add mirrors call-start (member; under admins_only, owner/admin). The added user gets a
  # participant row for THIS call only (never a conversation membership) and a `call:group_incoming` ring —
  # SAME payload shape as create_group_call's fan-out — so they can accept + join.
  defp group_add(%{"call_id" => call_id} = payload, socket)
       when is_binary(call_id) and call_id != "" do
    actor = current_user(socket)

    with {:ok, user_id} <- resolve_add_target(payload),
         {:ok, result} <-
           ConversationClient.add_call_participant(%{
             "call_id" => call_id,
             "actor_id" => actor,
             "user_id" => user_id
           }) do
      added = cget(result, :added_user_id) || user_id
      caller_name = resolve_name(actor)

      broadcast(socket, added, "call:group_incoming", %{
        call_id: call_id,
        room: cget(result, :room),
        conversation_id: cget(result, :conversation_id),
        type: cget(result, :type),
        caller_id: actor,
        caller_name: caller_name,
        participants: current_participants(call_id)
      })

      {:reply, {:ok, %{call_id: call_id, added_user_id: added}}, socket}
    else
      {:error, :user_not_found} -> reply_error(socket, "call.user_not_found")
      {:error, :call_add_forbidden} -> reply_error(socket, "call.add_forbidden")
      {:error, :invalid_request} -> reply_error(socket, "call.invalid_request")
      _ -> reply_error(socket, "call.unavailable")
    end
  end

  defp group_add(_payload, socket), do: reply_error(socket, "call.invalid_request")

  # Resolve the add target → user_id: an explicit "user_id" (existing member), or a "phone" looked up via
  # auth (v1: the phone must belong to an existing ACTIVE app user — a true SMS invite is out of scope).
  defp resolve_add_target(%{"user_id" => uid}) when is_binary(uid) and uid != "", do: {:ok, uid}

  defp resolve_add_target(%{"phone" => phone}) when is_binary(phone) and phone != "" do
    case SharedInfra.AuthClient.lookup_user_by_phone(%{"phone_number" => phone}) do
      {:ok, %{user_id: uid}} when is_binary(uid) and uid != "" -> {:ok, uid}
      {:ok, %{"user_id" => uid}} when is_binary(uid) and uid != "" -> {:ok, uid}
      _ -> {:error, :user_not_found}
    end
  rescue
    _ -> {:error, :user_not_found}
  end

  defp resolve_add_target(_payload), do: {:error, :invalid_request}

  # Live participant list for a call (best-effort) — used to seed the added user's ring payload.
  defp current_participants(call_id) do
    case ConversationClient.get_call_with_participants(%{"call_id" => call_id}) do
      {:ok, result} -> cget(result, :participants) || []
      _ -> []
    end
  end

  @doc """
  Group ring timeout (fired from the initiator's channel via `handle_info`). Flips any still-`invited`
  members to `missed` (idempotent — a join first makes it a no-op), then, if that closed the call (nobody
  joined), broadcasts `call:group_ended` to all participants. If people are in the call it stays ongoing —
  only stale invites were cleared. Mirrors the 1-on-1 timeout's re-check.
  """
  def group_ring_timeout(call_id, socket) when is_binary(call_id) do
    case ConversationClient.mark_group_participants_missed(%{"call_id" => call_id}) do
      {:ok, result} -> maybe_broadcast_group_ended(socket, call_id, cget(result, :call))
      _ -> :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  # Fan an event to a group call's participants (limited to `statuses`), excluding `exclude_user`
  # (pass nil to include everyone). Reads the live participant list; best-effort.
  defp broadcast_group(socket, call_id, exclude_user, statuses, event, payload) do
    case ConversationClient.get_call_with_participants(%{"call_id" => call_id}) do
      {:ok, result} ->
        (cget(result, :participants) || [])
        |> Enum.filter(&(cget(&1, :status) in statuses))
        |> Enum.map(&cget(&1, :user_id))
        |> Enum.reject(&(is_nil(&1) or &1 == exclude_user))
        |> Enum.each(&broadcast(socket, &1, event, payload))

      _ ->
        :ok
    end

    :ok
  end

  # When a group call has CLOSED (ended/missed), tell every participant to tear down. A call that closed as
  # `missed` (nobody ever joined) also drops ONE "Missed group call" entry into the conversation thread.
  defp maybe_broadcast_group_ended(socket, call_id, call) do
    status = cget(call, :status)

    if status in ["ended", "missed"] do
      broadcast_group(
        socket,
        call_id,
        nil,
        ["invited", "joined", "declined", "left", "missed"],
        "call:group_ended",
        %{call_id: call_id}
      )
    end

    if status == "missed", do: write_missed_group_message(call, socket)

    :ok
  end

  # Best-effort "Missed group call" chat entry (Slice B). Reuses the message create+broadcast path (same as
  # the 1-on-1 write_missed_message): one message_type=call row, sender = initiator, metadata.call_kind =
  # "group". Fans message_created to the conversation topic + each participant's user:<id>. Fire-and-forget:
  # a failed write never affects the (already-marked-missed) call.
  defp write_missed_group_message(call, socket) do
    conversation_id = cget(call, :conversation_id)
    caller_id = cget(call, :caller_id)
    call_id = cget(call, :id)

    if is_binary(conversation_id) and conversation_id != "" and is_binary(caller_id) do
      endpoint = socket.endpoint
      call_type = if cget(call, :type) == "video", do: "video", else: "voice"

      attrs = %{
        "conversation_id" => conversation_id,
        "sender_user_id" => caller_id,
        "message_type" => "call",
        "body" => "Missed group call",
        "metadata" => %{
          "call_id" => call_id,
          "call_type" => call_type,
          "call_kind" => "group",
          "status" => "missed"
        }
      }

      Task.start(fn ->
        with {:ok, response} <- SharedInfra.MessageClient.create_message(attrs) do
          endpoint.broadcast("conversation:" <> conversation_id, "message_created", response)

          case ConversationClient.get_call_with_participants(%{"call_id" => call_id}) do
            {:ok, result} ->
              (cget(result, :participants) || [])
              |> Enum.map(&cget(&1, :user_id))
              |> Enum.reject(&is_nil/1)
              |> Enum.each(&endpoint.broadcast("user:" <> &1, "message_created", response))

            _ ->
              :ok
          end
        else
          other -> Logger.warning("missed group-call chat write failed for #{call_id}: #{inspect(other)}")
        end
      end)
    end

    :ok
  rescue
    error -> Logger.warning("missed group-call chat write raised, ignored: #{inspect(error)}")
  end

  # --- helpers -----------------------------------------------------------------------------------

  # Fetch the call, resolve the caller's role, run `fun` only if the role is allowed.
  defp with_call(call_id, socket, allowed_roles, fun) when is_binary(call_id) and call_id != "" do
    me = current_user(socket)

    case ConversationClient.get_call(%{"call_id" => call_id}) do
      {:ok, call} ->
        role =
          cond do
            me == cget(call, :caller_id) -> :caller
            me == cget(call, :callee_id) -> :callee
            true -> :none
          end

        if role in allowed_roles do
          fun.(call, role)
        else
          reply_error(socket, "call.forbidden")
        end

      _ ->
        reply_error(socket, "call.not_found")
    end
  end

  defp with_call(_call_id, socket, _roles, _fun), do: reply_error(socket, "call.invalid_request")

  defp broadcast(socket, user_id, event, payload) when is_binary(user_id) and user_id != "" do
    socket.endpoint.broadcast("user:" <> user_id, event, payload)
    :ok
  end

  defp broadcast(_socket, _user_id, _event, _payload), do: :ok

  # Caller display name for the ring/push — best-effort (falls back to a short id).
  defp resolve_name(user_id) do
    case SharedInfra.UserClient.get_public_profile(%{"user_id" => user_id}) do
      {:ok, profile} ->
        name = Map.get(profile, :display_name) || Map.get(profile, "display_name")
        if is_binary(name) and name != "", do: name, else: short(user_id)

      _ ->
        short(user_id)
    end
  rescue
    _ -> short(user_id)
  end

  defp short(user_id) when is_binary(user_id), do: "#" <> String.slice(user_id, 0, 8)
  defp short(_), do: "Someone"

  # Drop a "missed call" entry into the DM thread (Slice-5b). Best-effort + fire-and-forget: the call is
  # ALREADY marked missed by the caller — a failed chat write must never crash signaling. Goes through the
  # SAME create+broadcast path as a normal message (MessageClient.create_message → message_created fan-out to
  # the conversation topic + both parties' user:<id>), so open clients get it live and the conversation row's
  # last-message/re-sort updates. sender = caller (so the existing own/other bubble alignment reads correct).
  # Requires the call row's conversation_id; if absent (call not tied to a conversation) we SKIP — the call
  # still shows in the Calls tab regardless.
  defp write_missed_message(call, socket) do
    conversation_id = cget(call, :conversation_id)
    caller_id = cget(call, :caller_id)
    callee_id = cget(call, :callee_id)

    if is_binary(conversation_id) and conversation_id != "" and is_binary(caller_id) do
      endpoint = socket.endpoint
      call_type = if cget(call, :type) == "video", do: "video", else: "voice"

      attrs = %{
        "conversation_id" => conversation_id,
        "sender_user_id" => caller_id,
        "message_type" => "call",
        # Short human body — powers the conversation-list preview + a11y fallback; the bubble itself renders
        # from metadata. metadata carries the structured detail for the client's styled "call" pill.
        "body" => "Missed #{call_type} call",
        "metadata" => %{"call_id" => cget(call, :id), "call_type" => call_type, "status" => "missed"}
      }

      Task.start(fn ->
        case SharedInfra.MessageClient.create_message(attrs) do
          {:ok, response} ->
            # Same fan-out a live message gets: conversation topic (open clients append) + each party's user
            # topic (unread/toast when closed). The frontend already dedupes (skips own-sender / open chat).
            endpoint.broadcast("conversation:" <> conversation_id, "message_created", response)
            if is_binary(callee_id), do: endpoint.broadcast("user:" <> callee_id, "message_created", response)
            endpoint.broadcast("user:" <> caller_id, "message_created", response)

          other ->
            Logger.warning("missed-call chat write failed for call #{cget(call, :id)}: #{inspect(other)}")
        end
      end)
    end

    :ok
  rescue
    error -> Logger.warning("missed-call chat write raised, ignored: #{inspect(error)}")
  end

  # Best-effort incoming-call push for a backgrounded callee. Reuses the message-push path: fire-and-forget
  # produce onto the Kafka bus (gated by CALL_PUSH_ENABLED); notification_service's CallIncomingConsumer
  # turns it into a web-push via PushSender. A no-op when the flag/Kafka path is off (same ceiling as
  # message pushes) — the reliable ring is the socket broadcast above; this is only the backgrounded case.
  defp emit_incoming_push(callee_id, caller_name, type, call_id) do
    if call_push_enabled?() do
      correlation = SharedInfra.Correlation.get_or_generate()

      Task.start(fn ->
        SharedInfra.Correlation.put(correlation)

        value =
          Jason.encode!(%{
            "type" => "call.incoming",
            "call_id" => call_id,
            "callee_id" => callee_id,
            "caller_name" => caller_name,
            "call_type" => type,
            "correlation_id" => correlation
          })

        SharedInfra.Kafka.Producer.produce(@call_events_topic, callee_id, value)
      end)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp call_push_enabled? do
    Application.get_env(:realtime_gateway, :call_push_enabled, false) ||
      System.get_env("CALL_PUSH_ENABLED") in ["true", "1", "yes"]
  end

  defp current_user(socket), do: socket.assigns.current_user_id

  # Call maps come atom-keyed (in-process CallStore) or string-keyed (HTTP adapter) — read either. Nil-safe
  # so nested reads (result → :call → :room_name) can pipe without crashing when a level is absent.
  defp cget(nil, _key), do: nil
  defp cget(call, key), do: Map.get(call, key) || Map.get(call, to_string(key))

  defp reply_error(socket, code), do: {:reply, {:error, %{code: code}}, socket}
end
