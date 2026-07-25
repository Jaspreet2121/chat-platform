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

  @doc """
  The ring timeout. The socket invite arms it in the caller's channel process; the /v1 create path arms a
  detached timer with the SAME value, read from here so the two can never drift. Config-overridable
  (`:realtime_gateway, :call_ring_timeout_ms`) ONLY so tests can shrink it — nothing sets it in prod.
  """
  def ring_timeout_ms,
    do: Application.get_env(:realtime_gateway, :call_ring_timeout_ms, @ring_timeout_ms)
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
  def handle_event("call:promote", payload, socket), do: promote(payload, socket)
  # Call links L3a — approval gate (joiner requests, host approves/denies).
  def handle_event("call:link_join_request", payload, socket), do: link_join_request(payload, socket)
  def handle_event("call:link_approve", payload, socket), do: link_approve(payload, socket)
  def handle_event("call:link_deny", payload, socket), do: link_deny(payload, socket)
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

            ring_callee(socket.endpoint, app_id(socket), %{
              call_id: call_id,
              room: room,
              caller_id: caller_id,
              callee_id: callee_id,
              type: type,
              conversation_id: cget(call, :conversation_id)
            })

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

  @doc """
  Ring the CALLEE of a freshly-created direct call: resolve the caller's display name + avatar, broadcast
  `call:incoming` to the callee's `user:<id>` topic, and emit the incoming-call web push (the only signal a
  BACKGROUNDED or socketless callee gets). ONE implementation for both entry points — the socket
  `call:invite` above and `POST /v1/calls` — so the wire payload can never fork between them.
  """
  def ring_callee(endpoint, app_id, %{
        call_id: call_id,
        room: room,
        caller_id: caller_id,
        callee_id: callee_id,
        type: type,
        conversation_id: conversation_id
      }) do
    {caller_name, caller_avatar_url} = resolve_caller(caller_id, app_id)

    do_broadcast(
      endpoint,
      callee_id,
      "call:incoming",
      %{
        call_id: call_id,
        room: room,
        caller_id: caller_id,
        caller_name: caller_name,
        type: type,
        conversation_id: conversation_id
      }
      |> put_avatar(caller_avatar_url)
    )

    emit_incoming_push(callee_id, caller_name, type, call_id)
    :ok
  end

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
      write_missed_message(call, socket.endpoint)
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
  def ring_timeout(call_id, endpoint) when is_binary(call_id) and is_atom(endpoint) do
    case ConversationClient.get_call(%{"call_id" => call_id}) do
      {:ok, call} ->
        if cget(call, :status) == "ringing" do
          _ = ConversationClient.mark_call_missed(%{"call_id" => call_id})
          write_missed_message(call, endpoint)
          do_broadcast(endpoint, cget(call, :caller_id), "call:missed", %{call_id: call_id})
          do_broadcast(endpoint, cget(call, :callee_id), "call:missed", %{call_id: call_id})
        end

      _ ->
        :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  # The socket form (the channel's handle_info) — same logic, endpoint taken from the socket.
  def ring_timeout(call_id, socket) when is_binary(call_id), do: ring_timeout(call_id, socket.endpoint)

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
        {caller_name, caller_avatar_url} = resolve_caller(initiator, app_id(socket))

        Enum.each(others, fn member_id ->
          broadcast(
            socket,
            member_id,
            "call:group_incoming",
            %{
              call_id: call_id,
              room: room,
              conversation_id: cid,
              type: type,
              caller_id: initiator,
              caller_name: caller_name,
              participants: parts
            }
            |> put_avatar(caller_avatar_url)
          )
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
      {caller_name, caller_avatar_url} = resolve_caller(actor, app_id(socket))

      broadcast(
        socket,
        added,
        "call:group_incoming",
        %{
          call_id: call_id,
          room: cget(result, :room),
          conversation_id: cget(result, :conversation_id),
          type: cget(result, :type),
          caller_id: actor,
          caller_name: caller_name,
          participants: current_participants(call_id)
        }
        |> put_avatar(caller_avatar_url)
      )

      {:reply, {:ok, %{call_id: call_id, added_user_id: added}}, socket}
    else
      {:error, :user_not_found} -> reply_error(socket, "call.user_not_found")
      {:error, :call_add_forbidden} -> reply_error(socket, "call.add_forbidden")
      {:error, :invalid_request} -> reply_error(socket, "call.invalid_request")
      _ -> reply_error(socket, "call.unavailable")
    end
  end

  defp group_add(_payload, socket), do: reply_error(socket, "call.invalid_request")

  # call:promote %{"call_id","user_id"} (existing member) OR %{"call_id","phone"} (outside person) — flip a
  # LIVE 1-on-1 (direct) call to a GROUP call in the SAME room (no reconnect): seat both current peers, add
  # + ring the new person, and tell the OTHER peer to swap to group UI. actor = current_user (never trusted);
  # either peer of a 1-on-1 may promote. Does NOT touch the 1-on-1 invite/accept/hangup handlers.
  defp promote(%{"call_id" => call_id} = payload, socket)
       when is_binary(call_id) and call_id != "" do
    actor = current_user(socket)

    with {:ok, user_id} <- resolve_add_target(payload),
         {:ok, result} <-
           ConversationClient.promote_direct_to_group(%{
             "call_id" => call_id,
             "actor_id" => actor,
             "user_id" => user_id
           }) do
      added = cget(result, :added_user_id) || user_id
      room = cget(result, :room)
      cid = cget(result, :conversation_id)
      type = cget(result, :type)
      {caller_name, caller_avatar_url} = resolve_caller(actor, app_id(socket))

      # (a) Ring the NEW person — same payload shape as create_group_call / group_add fan-out.
      broadcast(
        socket,
        added,
        "call:group_incoming",
        %{
          call_id: call_id,
          room: room,
          conversation_id: cid,
          type: type,
          caller_id: actor,
          caller_name: caller_name,
          participants: current_participants(call_id)
        }
        |> put_avatar(caller_avatar_url)
      )

      # (b) Tell the OTHER existing peer (everyone in the call but the actor) the call became a group, so
      # their client swaps 1-on-1 → group UI. The actor's own client swaps locally on this ok reply.
      (cget(result, :existing_parties) || [])
      |> Enum.reject(&(&1 == actor))
      |> Enum.each(fn peer ->
        broadcast(socket, peer, "call:promoted", %{
          call_id: call_id,
          room: room,
          conversation_id: cid,
          type: type,
          new_user_id: added,
          actor_id: actor
        })
      end)

      {:reply, {:ok, %{call_id: call_id, room: room, conversation_id: cid, type: type}}, socket}
    else
      {:error, :user_not_found} -> reply_error(socket, "call.user_not_found")
      {:error, :promote_forbidden} -> reply_error(socket, "call.forbidden")
      {:error, :invalid_request} -> reply_error(socket, "call.invalid_request")
      _ -> reply_error(socket, "call.unavailable")
    end
  end

  defp promote(_payload, socket), do: reply_error(socket, "call.invalid_request")

  # ============================================================================================
  # Call links L3a — approval gate. A pending joiner asks the host to admit them; the host approves/denies.
  # The host is the link call's caller_id (first joiner). Actor is ALWAYS current_user(socket).
  # ============================================================================================

  # call:link_join_request %{"call_id"} — sent BY a pending joiner. Ring the host with an approve/deny prompt.
  defp link_join_request(%{"call_id" => call_id}, socket)
       when is_binary(call_id) and call_id != "" do
    actor = current_user(socket)

    case ConversationClient.get_call(%{"call_id" => call_id}) do
      {:ok, call} ->
        host = cget(call, :caller_id)

        if is_binary(host) and host != actor do
          broadcast(socket, host, "call:link_incoming_request", %{
            call_id: call_id,
            user_id: actor,
            user_name: resolve_name(actor, app_id(socket))
          })
        end

        {:reply, {:ok, %{call_id: call_id}}, socket}

      _ ->
        reply_error(socket, "call.not_found")
    end
  end

  defp link_join_request(_payload, socket), do: reply_error(socket, "call.invalid_request")

  # call:link_approve %{"call_id","user_id"} — host admits the joiner. Flip their row → joined (the token now
  # authorizes them) and tell them the room so they can connect.
  defp link_approve(%{"call_id" => call_id, "user_id" => user_id}, socket)
       when is_binary(call_id) and call_id != "" and is_binary(user_id) and user_id != "" do
    host = current_user(socket)

    case ConversationClient.approve_link_participant(%{
           "call_id" => call_id,
           "actor_id" => host,
           "user_id" => user_id
         }) do
      {:ok, result} ->
        broadcast(socket, user_id, "call:link_approved", %{
          call_id: call_id,
          room: cget(result, :room),
          type: cget(result, :type)
        })

        {:reply, {:ok, %{call_id: call_id, user_id: user_id}}, socket}

      {:error, :not_host} ->
        reply_error(socket, "call.forbidden")

      _ ->
        reply_error(socket, "call.unavailable")
    end
  end

  defp link_approve(_payload, socket), do: reply_error(socket, "call.invalid_request")

  # call:link_deny %{"call_id","user_id"} — host rejects the joiner. Drop their row (no token) + tell them.
  defp link_deny(%{"call_id" => call_id, "user_id" => user_id}, socket)
       when is_binary(call_id) and call_id != "" and is_binary(user_id) and user_id != "" do
    host = current_user(socket)

    case ConversationClient.deny_link_participant(%{
           "call_id" => call_id,
           "actor_id" => host,
           "user_id" => user_id
         }) do
      {:ok, _result} ->
        broadcast(socket, user_id, "call:link_denied", %{call_id: call_id})
        {:reply, {:ok, %{call_id: call_id, user_id: user_id}}, socket}

      {:error, :not_host} ->
        reply_error(socket, "call.forbidden")

      _ ->
        reply_error(socket, "call.unavailable")
    end
  end

  defp link_deny(_payload, socket), do: reply_error(socket, "call.invalid_request")

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

  defp broadcast(socket, user_id, event, payload),
    do: do_broadcast(socket.endpoint, user_id, event, payload)

  defp do_broadcast(endpoint, user_id, event, payload) when is_binary(user_id) and user_id != "" do
    endpoint.broadcast("user:" <> user_id, event, payload)
    :ok
  end

  defp do_broadcast(_endpoint, _user_id, _event, _payload), do: :ok

  # Caller display name for the ring/push — best-effort (falls back to a short id). MUST pass the socket's
  # app_id: get_public_profile is app-scoped (a1ce358) and returns :profile_invalid without it, which is
  # exactly the bug that made rings show "#0db187fe" instead of a name.
  defp resolve_name(user_id, app_id) do
    case SharedInfra.UserClient.get_public_profile(%{"user_id" => user_id, "app_id" => app_id}) do
      {:ok, profile} -> display_name(profile, user_id)
      _ -> short(user_id)
    end
  rescue
    _ -> short(user_id)
  end

  # Resolve BOTH the caller's display name and a presigned avatar URL in ONE profile fetch — the ring payload
  # carries what the callee needs to render the incoming screen with no extra round-trip. Fully best-effort:
  # any failure yields {short_id, nil} so a ring is never blocked by a profile/media hiccup.
  defp resolve_caller(user_id, app_id) do
    case SharedInfra.UserClient.get_public_profile(%{"user_id" => user_id, "app_id" => app_id}) do
      {:ok, profile} -> {display_name(profile, user_id), presign_avatar(profile, app_id)}
      _ -> {short(user_id), nil}
    end
  rescue
    _ -> {short(user_id), nil}
  end

  defp display_name(profile, user_id) do
    case Map.get(profile, :display_name) || Map.get(profile, "display_name") do
      name when is_binary(name) and name != "" -> name
      _ -> short(user_id)
    end
  end

  # Presign the caller's avatar, scoped to app_id + purpose "user_avatar" (the SAME path the gateway's
  # avatar route uses — NOT the HMAC push-token route, which exists only for pushes that outlive short TTLs;
  # a ring is answered in seconds, so a normal presigned URL is correct). No avatar_media_id, a cross-tenant
  # asset, or any media error → nil (the field is then omitted; the client falls back to initials).
  defp presign_avatar(profile, app_id) when is_binary(app_id) and app_id != "" do
    with media_id when is_binary(media_id) and media_id != "" <-
           Map.get(profile, :avatar_media_id) || Map.get(profile, "avatar_media_id"),
         {:ok, download} <-
           SharedInfra.MediaClient.get_download_url(%{
             "media_id" => media_id,
             "app_id" => app_id,
             "purpose" => "user_avatar"
           }),
         url when is_binary(url) and url != "" <-
           Map.get(download, :download_url) || Map.get(download, "download_url") do
      url
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp presign_avatar(_profile, _app_id), do: nil

  # Add caller_avatar_url ONLY when we actually have one — the client treats an ABSENT field as "no avatar"
  # (renders initials); we never send null/"".
  defp put_avatar(payload, url) when is_binary(url) and url != "",
    do: Map.put(payload, :caller_avatar_url, url)

  defp put_avatar(payload, _url), do: payload

  # The tenant this socket belongs to (set by UserSocket.assign_session via Tenancy.app_id_or_default).
  defp app_id(socket), do: Map.get(socket.assigns, :app_id)

  defp short(user_id) when is_binary(user_id), do: "#" <> String.slice(user_id, 0, 8)
  defp short(_), do: "Someone"

  # Drop a "missed call" entry into the DM thread (Slice-5b). Best-effort + fire-and-forget: the call is
  # ALREADY marked missed by the caller — a failed chat write must never crash signaling. Goes through the
  # SAME create+broadcast path as a normal message (MessageClient.create_message → message_created fan-out to
  # the conversation topic + both parties' user:<id>), so open clients get it live and the conversation row's
  # last-message/re-sort updates. sender = caller (so the existing own/other bubble alignment reads correct).
  # Requires the call row's conversation_id; if absent (call not tied to a conversation) we SKIP — the call
  # still shows in the Calls tab regardless.
  defp write_missed_message(call, endpoint) do
    conversation_id = cget(call, :conversation_id)
    caller_id = cget(call, :caller_id)
    callee_id = cget(call, :callee_id)

    if is_binary(conversation_id) and conversation_id != "" and is_binary(caller_id) do
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

        # The GATEWAY'S OWN brod client — the producer's default is :message_service_kafka_client, which
        # exists only in the message-service release; producing without this option is exactly the bug that
        # made call pushes silently never fire (see RealtimeGateway.Application.kafka_children/0).
        case SharedInfra.Kafka.Producer.produce(@call_events_topic, callee_id, value,
               client: RealtimeGateway.Application.kafka_client_name()
             ) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            # Fire-and-forget stays (a push hiccup must never break the ring) — but resilience is not
            # invisibility: a dead client / broker shows up in the logs instead of vanishing.
            Logger.warning(
              "call.incoming push produce failed (call #{call_id}): #{inspect(reason)}"
            )
        end
      end)
    end

    :ok
  rescue
    _ -> :ok
  end

  # Public (doc-hidden) so RealtimeGateway.Application's brod-client gate reuses THIS predicate — one
  # definition of "call push is on", no drift between the producer and its client's supervision.
  @doc false
  def call_push_enabled? do
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
