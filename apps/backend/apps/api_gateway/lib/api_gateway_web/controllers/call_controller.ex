defmodule ApiGatewayWeb.CallController do
  @moduledoc """
  Phase-1 calling — LiveKit access tokens. Mints a room-scoped LiveKit JWT for the authenticated user so
  the client can join the SFU. Slice 1 accepts a room name directly; call-row validation (that the user is
  a participant of that call) arrives in a later slice.
  """
  use ApiGatewayWeb, :controller

  require Logger

  # 130-group: the dead-timer backstop rides every call endpoint (see ApiGatewayWeb.CallReaper).
  # Claims a 60 s slot per node and does its work in a Task — the request never waits for it.
  plug :maybe_reap

  defp maybe_reap(conn, _opts) do
    ApiGatewayWeb.CallReaper.maybe_reap()
    conn
  end

  alias ApiGatewayWeb.ErrorResponse

  # GET /api/v1/calls?cursor=&limit= → { "calls": [ …, counterpart_id, counterpart_name ],
  # "next_cursor": <opaque|null> } for the current user. Call history (both sides), newest first, keyset
  # pagination — served from conversation_service's CallStore, SCOPED to the session's tenant (097: rows
  # stamped with another app never appear; NULL-app legacy rows still do). Each row is enriched
  # server-side with the OTHER party's display name (batched, one profile lookup per unique id); the
  # avatar is resolved client-side via the shared cached useUserProfile hook (same as every chat row).
  # DB flag off (`{:error, :call_unavailable}`) or any read failure → 200 { calls: [] } (never a 500) —
  # but LOGGED with the ids it filtered by, because a silently-empty list is a diagnosis dead end
  # (2026-08-16: an empty list took a device session to even notice).
  def index(conn, params) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}) do
      {cursor_ts, cursor_id} = decode_cursor(Map.get(params, "cursor"))

      attrs =
        %{
          "user_id" => session.user_id,
          "app_id" => session_app(session),
          "limit" => Map.get(params, "limit"),
          "cursor_ts" => cursor_ts,
          "cursor_id" => cursor_id
        }
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()

      {calls, next_cursor} =
        case SharedInfra.ConversationClient.list_calls_for_user(attrs) do
          {:ok, %{calls: calls} = result} when is_list(calls) ->
            {calls, cget(result, :next_cursor)}

          {:ok, %{"calls" => calls} = result} when is_list(calls) ->
            {calls, cget(result, :next_cursor)}

          other ->
            Logger.warning(
              "calls list read failed → 200 empty (user=#{session.user_id} " <>
                "app=#{inspect(session_app(session))}): #{inspect(other)}"
            )

            {[], nil}
        end

      json(conn, %{
        calls: enrich(calls, session.user_id, session_app(session)),
        next_cursor: encode_cursor(next_cursor)
      })
    else
      _ -> ErrorResponse.unauthorized(conn, "auth.unauthorized", "Invalid or missing session")
    end
  end

  # POST /api/v1/calls/token  { "room": "<room_name>" }
  # → { "url": "wss://…", "token": "<livekit jwt>" } for the current user + room. The user must BELONG to
  # the call the room names (`authorize_call/2`) — otherwise 403. This closes the Phase-1 auth gap where any
  # authenticated user could mint a token for any room.
  def token(conn, %{"room" => room}) when is_binary(room) and room != "" do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         :ok <- authorize_call(room, session.user_id),
         {:ok, jwt} <-
           SharedInfra.LiveKitToken.create(session.user_id, room, name: session.user_id) do
      json(conn, %{url: SharedInfra.LiveKitToken.url(), token: jwt})
    else
      {:error, :livekit_not_configured} ->
        ErrorResponse.service_unavailable(conn, "calls.unavailable")

      {:error, :call_forbidden} ->
        ErrorResponse.forbidden(conn, "calls.forbidden", "Not authorized for this call")

      _ ->
        ErrorResponse.unauthorized(conn, "auth.unauthorized", "Invalid or missing session")
    end
  end

  def token(conn, _params), do: ErrorResponse.invalid_request(conn, "calls.room_required")

  # POST /api/v1/calls/:id/reject — the CALLEE declines a ringing 1-on-1 call from the FIRST-PARTY app.
  #
  # WHY THIS EXISTS (the closed-app gap): with incoming-call FCM live, the callee's handset rings while the app
  # (and its socket) is CLOSED. Tapping Decline then has NO socket to push `call:reject` over, so without this
  # the decline is simply lost and the call resolves as a server ring-TIMEOUT (missed) 35s later. This is
  # Decline's session-authed REST path — mirroring the socket handler's semantics EXACTLY
  # (RealtimeGateway.CallSignaling.reject/2): mark the call declined, tell the caller (`call:rejected`), and
  # write the SAME missed pill (indistinguishable from a missed call — see write_missed_message). Reusing the
  # shared primitives (ConversationClient.mark_call_declined + CallSignaling.write_missed_message), not a
  # second implementation.
  #
  # reject ONLY (not accept/end): a dismissed incoming-call notification never brings the socket up, so the
  # decline has no other way home. accept/end self-heal — accepting inherently foregrounds the app, its socket
  # connects, and the socket handlers apply — so they need no closed-app REST twin.
  #
  # Errors: not the callee → 403 forbidden; unknown call → 404; a call that already left "ringing" (the 35s
  # timeout won the race, or a double-tap) → idempotent 200 with NO second transition/pill/broadcast. A decline
  # arriving after the timeout MUST NOT 500 or double-write the pill.
  def reject(conn, %{"id" => call_id}) when is_binary(call_id) and call_id != "" do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, call} <- fetch_call(call_id) do
      # 130-group: ONE endpoint, two flows. A direct call's decline is the callee's alone; a
      # group/adhoc/link decline is any participant's, and writes their own row.
      case cget(call, :kind) || "direct" do
        "direct" ->
          with :ok <- ensure_callee(call, session.user_id) do
            decline_ringing_call(conn, call, call_id)
          else
            {:error, :forbidden} ->
              ErrorResponse.forbidden(
                conn,
                "calls.forbidden",
                "Only the callee can decline this call"
              )
          end

        _group_like ->
          decline_group_call(conn, call, call_id, session.user_id)
      end
    else
      {:error, :not_found} ->
        ErrorResponse.not_found(conn, "calls.not_found", "Call not found")

      {:error, :forbidden} ->
        ErrorResponse.forbidden(conn, "calls.forbidden", "Only the callee can decline this call")

      _ ->
        ErrorResponse.unauthorized(conn, "auth.unauthorized", "Invalid or missing session")
    end
  end

  def reject(conn, _params), do: ErrorResponse.invalid_request(conn, "calls.invalid_request")

  @doc """
  POST /api/v1/calls/:id/join — the REST twin of `call:group_join` (130-group).

  WHY IT EXISTS: a group member woken by a VoIP/FCM push has no socket yet. Answering must not wait
  for one, so this seats them `joined` through the SAME store transition the socket handler uses
  (ConversationClient.join_group_call — first join flips the call ringing → ongoing), broadcasts the
  same `call:participant_joined` to the invited+joined members, and emits the same "answered" stop
  to the member's own other devices. Reply = the socket reply's shape, so the client fetches a
  LiveKit token next exactly as it would after a socket join.

  Group/adhoc/link only. A direct call is answered by the callee over the socket (or the /v1
  accept), and a non-participant is told the call does not exist (404), never that it does.
  """
  def join(conn, %{"id" => call_id}) when is_binary(call_id) and call_id != "" do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, call} <- fetch_call(call_id),
         :ok <- ensure_group_like(call),
         :ok <- ensure_party(call, session.user_id) do
      case SharedInfra.ConversationClient.join_group_call(%{
             "call_id" => call_id,
             "user_id" => session.user_id
           }) do
        {:ok, result} ->
          joined = cget(result, :participant)

          broadcast_to_participants(
            call_id,
            session.user_id,
            ["invited", "joined"],
            "call:participant_joined",
            %{
              call_id: call_id,
              user_id: session.user_id,
              joined_at: cget(joined, :joined_at)
            }
          )

          RealtimeGateway.CallSignaling.emit_group_cancel_push(
            call_id,
            session.user_id,
            "answered"
          )

          json(conn, %{
            call_id: call_id,
            room: cget(cget(result, :call), :room_name) || cget(call, :room_name),
            participants: participants_of(call_id)
          })

        {:error, :call_ended} ->
          ErrorResponse.conflict(conn, "calls.ended", "This call has ended")

        _ ->
          ErrorResponse.service_unavailable(conn, "calls.unavailable")
      end
    else
      {:error, :not_found} -> ErrorResponse.not_found(conn, "calls.not_found", "Call not found")
      {:error, :forbidden} -> ErrorResponse.not_found(conn, "calls.not_found", "Call not found")
      {:error, :not_group} -> ErrorResponse.invalid_request(conn, "calls.not_group_call")
      _ -> ErrorResponse.unauthorized(conn, "auth.unauthorized", "Invalid or missing session")
    end
  end

  def join(conn, _params), do: ErrorResponse.invalid_request(conn, "calls.invalid_request")

  defp ensure_group_like(call) do
    if (cget(call, :kind) || "direct") in ["group", "adhoc", "link"],
      do: :ok,
      else: {:error, :not_group}
  end

  # The group/adhoc/link decline (130-group): the caller's OWN participant row is what changes, so
  # authorization is participation, exactly as show/token check it. Idempotent: a member who already
  # declined, or a call that already closed, gets 200 and nothing is written or broadcast again —
  # the closed-app double-tap and the timeout race both land here. A non-participant gets 404, the same
  # answer as a call that does not exist.
  defp decline_group_call(conn, call, call_id, user_id) do
    with :ok <- ensure_party(call, user_id) do
      already =
        cget(call, :status) in ["ended", "missed", "cancelled"] or
          participant_status(call_id, user_id) == "declined"

      if already do
        json(conn, %{call_id: call_id})
      else
        case SharedInfra.ConversationClient.decline_group_call(%{
               "call_id" => call_id,
               "user_id" => user_id
             }) do
          {:ok, _result} ->
            broadcast_to_participants(
              call_id,
              user_id,
              ["invited", "joined"],
              "call:participant_declined",
              %{call_id: call_id, user_id: user_id}
            )

            RealtimeGateway.CallSignaling.emit_group_cancel_push(call_id, user_id, "declined")
            json(conn, %{call_id: call_id})

          _ ->
            ErrorResponse.service_unavailable(conn, "calls.unavailable")
        end
      end
    else
      {:error, :forbidden} -> ErrorResponse.not_found(conn, "calls.not_found", "Call not found")
    end
  end

  defp participants_of(call_id) do
    case SharedInfra.ConversationClient.get_call_with_participants(%{"call_id" => call_id}) do
      {:ok, result} -> cget(result, :participants) || []
      _ -> []
    end
  end

  defp participant_status(call_id, user_id) do
    call_id
    |> participants_of()
    |> Enum.find(&(cget(&1, :user_id) == user_id))
    |> cget(:status)
  end

  # The gateway-side twin of CallSignaling.broadcast_group/6: every participant in `statuses` except the
  # actor, over their user topic, from this release's endpoint.
  defp broadcast_to_participants(call_id, actor, statuses, event, payload) do
    call_id
    |> participants_of()
    |> Enum.filter(&(cget(&1, :status) in statuses))
    |> Enum.map(&cget(&1, :user_id))
    |> Enum.reject(&(is_nil(&1) or &1 == actor))
    |> Enum.each(fn user_id ->
      Task.start(fn ->
        try do
          ApiGatewayWeb.Endpoint.broadcast("user:" <> user_id, event, payload)
        rescue
          _ -> :ok
        end
      end)
    end)

    :ok
  end

  # Call-authorize a LiveKit token request. The room is "call-"<>call_id; we resolve the call row and check
  # the user belongs to it: GROUP calls authorize on a `group_call_participants` row (invited or joined —
  # an added non-member is authorized for THIS call only); DIRECT calls authorize on caller/callee. Anything
  # unresolvable (room not "call-…", call not found, service/DB unavailable, lookup raise) FAILS CLOSED to
  # :call_forbidden. A real call can't exist without persistence, so `get_call` resolves every genuine call —
  # existing 1-on-1 tokens still issue via the caller/callee branch.
  defp authorize_call("call-" <> call_id, user_id) when call_id != "" and is_binary(user_id) do
    case SharedInfra.ConversationClient.get_call(%{"call_id" => call_id}) do
      {:ok, call} ->
        if authorized_for_call?(call, call_id, user_id), do: :ok, else: {:error, :call_forbidden}

      _ ->
        {:error, :call_forbidden}
    end
  rescue
    _ -> {:error, :call_forbidden}
  end

  defp authorize_call(_room, _user_id), do: {:error, :call_forbidden}

  defp authorized_for_call?(call, call_id, user_id) do
    case cget(call, :kind) || "direct" do
      # GROUP + LINK (L1) calls authorize the same way — a group_call_participants row for (call, user).
      # A link call has no caller/callee, only join-created participant rows.
      kind when kind in ["group", "link", "adhoc"] ->
        case SharedInfra.ConversationClient.call_participant?(%{
               "call_id" => call_id,
               "user_id" => user_id
             }) do
          {:ok, %{authorized: true}} -> true
          {:ok, %{"authorized" => true}} -> true
          _ -> false
        end

      _ ->
        user_id == cget(call, :caller_id) or user_id == cget(call, :callee_id)
    end
  end

  defp authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token = authorization] when token != "" -> {:ok, authorization}
      _ -> {:error, :session_invalid}
    end
  end

  @doc """
  GET /api/v1/calls/:id — one call's live state, for the CALLEE woken by a push.

  THIS ENDPOINT EXISTS FOR E2EE (111 / E2EE_FRAME.md §calls). The incoming-call push is data-only and
  deliberately small (FCM caps data payloads, and the ring push must fit inside the 35s ring window),
  so the sealed key envelopes CANNOT ride it. A backgrounded callee therefore wakes on the push and
  fetches the call here to find the envelope addressed to its own device.

  Session-authed and scoped to the two parties: only the caller or the callee of THIS call may read
  it (a group call authorizes on participation, same predicate the token endpoint uses). Anyone else
  gets 404 — a call id must not confirm its own existence to a stranger.

  Once the call reaches a terminal state the server has scrubbed `e2ee_offer` to null; the response
  then carries only the durable `e2ee` / `e2ee_accepted` booleans. Fetching a finished call is
  therefore useless for key recovery BY DESIGN — the key died with the call.
  """
  def show(conn, %{"id" => call_id}) when is_binary(call_id) and call_id != "" do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, call} <- fetch_call(call_id),
         :ok <- ensure_party(call, session.user_id) do
      json(conn, present_call_state(call))
    else
      # Not a party to the call reads exactly like a call that does not exist.
      {:error, :forbidden} -> ErrorResponse.not_found(conn, "calls.not_found", "Call not found")
      {:error, :not_found} -> ErrorResponse.not_found(conn, "calls.not_found", "Call not found")
      _ -> ErrorResponse.unauthorized(conn, "auth.unauthorized", "Invalid or missing session")
    end
  end

  def show(conn, _params), do: ErrorResponse.invalid_request(conn, "calls.invalid_request")

  # Caller or callee of a direct call; a participant of a group/link/adhoc call. ONE predicate, shared
  # with the token path (authorized_for_call?/3) — this used to be a second helper that matched
  # `%{participant: true}`, a shape CallStore.call_participant? never returns (it answers
  # `%{authorized: boolean}`), so every group, link and adhoc invitee got 404 here while the SAME
  # user could mint a LiveKit token two routes over. The push-woken invitee could join the room and
  # still not read the sealed e2ee_offer this endpoint exists to serve.
  defp ensure_party(call, user_id) when is_binary(user_id) do
    if authorized_for_call?(call, cget(call, :id), user_id), do: :ok, else: {:error, :forbidden}
  end

  defp ensure_party(_call, _user_id), do: {:error, :forbidden}

  # The live-state view. Deliberately NOT the history presenter: history masks the status per viewer
  # (declined reads as missed to the caller) and drops fields — a ringing callee needs the raw truth,
  # plus the room to join and the sealed offer to open.
  defp present_call_state(call) do
    %{
      "id" => cget(call, :id),
      "room_name" => cget(call, :room_name),
      "kind" => cget(call, :kind) || "direct",
      "caller_id" => cget(call, :caller_id),
      "callee_id" => cget(call, :callee_id),
      "conversation_id" => cget(call, :conversation_id),
      "type" => cget(call, :type),
      "status" => cget(call, :status),
      "created_at" => cget(call, :created_at),
      "answered_at" => cget(call, :answered_at),
      "ended_at" => cget(call, :ended_at),
      # E2EE: the booleans are always present; the offer is null once the call ended (scrubbed).
      "e2ee" => cget(call, :e2ee) || false,
      "e2ee_accepted" => cget(call, :e2ee_accepted),
      "e2ee_offer" => cget(call, :e2ee_offer)
    }
  end

  # --- first-party decline (reject/2) helpers ----------------------------------------------------

  defp fetch_call(call_id) do
    case SharedInfra.ConversationClient.get_call(%{"call_id" => call_id}) do
      {:ok, call} -> {:ok, call}
      _ -> {:error, :not_found}
    end
  end

  # 1-on-1 only: the direct call's callee is the single answerer. A group call (kind != "direct") has no single
  # callee, so a decline there fails closed to 403 — group decline/leave is a separate flow (its own follow-up).
  defp ensure_callee(call, user_id) do
    if (cget(call, :kind) || "direct") == "direct" and is_binary(user_id) and
         user_id == cget(call, :callee_id),
       do: :ok,
       else: {:error, :forbidden}
  end

  defp decline_ringing_call(conn, call, call_id) do
    if cget(call, :status) == "ringing" do
      # `expected_status` makes the transition ATOMIC: if the 35s ring-timeout (or another device) already
      # moved the call out of "ringing" under the row lock, mark_call_declined returns :call_conflict and we
      # treat the whole thing as an idempotent success — the timeout already wrote its missed pill, and a
      # second pill must never appear. This is the closed-app decline's race guard.
      case SharedInfra.ConversationClient.mark_call_declined(%{
             "call_id" => call_id,
             "expected_status" => "ringing"
           }) do
        {:ok, _} ->
          notify_caller_rejected(cget(call, :caller_id), call_id)

          # The SAME missed pill the socket reject writes (one definition, no drift) — a REST decline and a
          # socket decline are indistinguishable in the chat, and both are indistinguishable from a missed call.
          RealtimeGateway.CallSignaling.write_missed_message(call, ApiGatewayWeb.Endpoint)
          json(conn, %{call_id: call_id})

        {:error, :call_conflict} ->
          json(conn, %{call_id: call_id})

        _ ->
          ErrorResponse.service_unavailable(conn, "calls.unavailable")
      end
    else
      # Already terminal (declined / missed / ended / answered) → idempotent success, no side effects. A decline
      # after the ring-timeout is normal (closed app), and must never 500 or re-write the pill.
      json(conn, %{call_id: call_id})
    end
  end

  # Resolve the caller's ring with `call:rejected`. Reaches the caller's SDK because RealtimeGateway.UserSocket
  # is mounted on ApiGatewayWeb.Endpoint (one endpoint, one PubSub) — the same path the /v1 twin and the socket
  # handler use. Fire-and-forget: a PubSub hiccup must never fail the decline (the call IS already declined),
  # but it must not vanish either (the caller would otherwise ring to the 35s timeout).
  defp notify_caller_rejected(caller_id, call_id) when is_binary(caller_id) and caller_id != "" do
    Task.start(fn ->
      try do
        ApiGatewayWeb.Endpoint.broadcast("user:" <> caller_id, "call:rejected", %{
          call_id: call_id
        })
      rescue
        error ->
          Logger.error("first-party call:rejected broadcast failed: #{Exception.message(error)}")
      end
    end)

    :ok
  end

  defp notify_caller_rejected(_caller_id, _call_id), do: :ok

  # Normalize each call to a stable string-keyed shape + the counterpart id, then batch-enrich names
  # (one profile lookup per UNIQUE counterpart, not per row).
  # THE DECLINE IS NEVER REVEALED TO THE CALLER — the Calls tab is masked the same way the chat pill is.
  #
  # `CallSignaling.reject/2` deliberately writes a pill whose metadata.status is "missed", not
  # "declined": "a DECLINED call must be INDISTINGUISHABLE from a missed one in the chat — the caller
  # must never learn they were actively declined" (WhatsApp semantics). That decision was made for the
  # transcript and never applied here, so the SAME call read two different ways in two places in the
  # same app: the pill said "No answer" while this row said "Declined". The pill was right; this was
  # the leak.
  #
  # Masked for the CALLER ONLY. The callee performed the decline, so showing them their own action
  # reveals nothing and is genuinely useful history — hiding it from them would lose information for
  # no privacy gain.
  #
  # NOT masked on `/v1`: that surface answers to the INTEGRATOR (the app owner), a different audience
  # from the end user placing the call, and the `call.declined` webhook exists precisely to tell them.
  # The rule is "the caller must not learn", not "the fact is secret".
  defp viewer_status("declined", caller_id, me)
       when is_binary(me) and caller_id == me,
       do: "missed"

  # 097, the inverse masking: a caller-CANCELLED ring reads "cancelled" to the caller (their own action)
  # and "missed" to everyone else — to the callee it IS a missed call, and the pill already says so.
  defp viewer_status("cancelled", caller_id, me)
       when is_binary(me) and caller_id != me,
       do: "missed"

  defp viewer_status(status, _caller_id, _me), do: status

  # A GROUP call the viewer DECLINED reads "declined" to them — their own action, nothing to mask
  # (the caller-side masking above is about a direct callee's refusal). The call row's status is
  # the call's outcome for everyone else; the participant row is the viewer's. duration stays 0:
  # they never connected. Direct rows never carry a participant status.
  defp group_decline(_status, "group", "declined"), do: "declined"
  defp group_decline(status, _kind, _participant_status), do: status

  # The terminal contract vocabulary (2026-08-16 spec), applied BEFORE the viewer mask: a
  # connected-then-finished call presents as "answered" (the DB's "ended" is the transition name, not
  # the outcome; answered_at proves connection). An "ended" row that never connected (legacy
  # hangup-on-ringing) reads "cancelled" — which the mask then shows the callee as "missed".
  defp outcome("ended", answered_at) when is_binary(answered_at) and answered_at != "",
    do: "answered"

  defp outcome("ended", _never_answered), do: "cancelled"
  defp outcome(status, _answered_at), do: status

  defp enrich(calls, me, app_id) do
    rows = Enum.map(calls, &present_call(&1, me))

    names =
      rows
      |> Enum.map(& &1["counterpart_id"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Map.new(fn id -> {id, resolve_name(id, app_id)} end)

    Enum.map(rows, fn row ->
      Map.put(row, "counterpart_name", Map.get(names, row["counterpart_id"]))
    end)
  end

  defp present_call(call, me) do
    kind = cget(call, :kind) || "direct"
    caller_id = cget(call, :caller_id)
    callee_id = cget(call, :callee_id)

    # Direct calls have a single counterpart (the OTHER party). Group calls have no single counterpart
    # (callee_id is NULL) — leave it nil; the client renders group rows from `kind`.
    counterpart_id =
      if kind == "group", do: nil, else: if(caller_id == me, do: callee_id, else: caller_id)

    %{
      "id" => cget(call, :id),
      "room_name" => cget(call, :room_name),
      "kind" => kind,
      "caller_id" => caller_id,
      "callee_id" => callee_id,
      "conversation_id" => cget(call, :conversation_id),
      "type" => cget(call, :type),
      "status" =>
        cget(call, :status)
        |> outcome(cget(call, :answered_at))
        |> viewer_status(caller_id, me)
        |> group_decline(kind, cget(call, :participant_status)),
      "created_at" => cget(call, :created_at),
      "answered_at" => cget(call, :answered_at),
      "ended_at" => cget(call, :ended_at),
      # E2EE (111): `e2ee` says an encrypted call was OFFERED and survives the end-of-call envelope
      # scrub, so a past call can still draw its lock badge; `e2ee_accepted` is the mode the two
      # clients actually agreed (nil when the call was never answered). The envelopes are long gone.
      "e2ee" => cget(call, :e2ee) || false,
      "e2ee_accepted" => cget(call, :e2ee_accepted),
      # The recorded first-party rule: 0 (not nil) for a call that never connected. The /v1 webhook keeps
      # its own recorded nil — two surfaces, two recorded contracts, one raw source (CallStore).
      "duration_seconds" =>
        if(cget(call, :participant_status) == "declined" and kind == "group",
          do: 0,
          else: cget(call, :duration_seconds) || 0
        ),
      "counterpart_id" => counterpart_id
    }
  end

  # Best-effort display name for a counterpart uuid (nil → the client falls back to a short id/initials).
  # get_public_profile is app-scoped (a1ce358) — WITHOUT app_id it returns :profile_invalid and every row's
  # name silently became nil. app_id is the caller's session tenant (the counterpart is in the same app).
  defp resolve_name(user_id, app_id)
       when is_binary(user_id) and user_id != "" and is_binary(app_id) and app_id != "" do
    case SharedInfra.UserClient.get_public_profile(%{"user_id" => user_id, "app_id" => app_id}) do
      {:ok, profile} ->
        name = Map.get(profile, :display_name) || Map.get(profile, "display_name")
        if is_binary(name) and name != "", do: name, else: nil

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp resolve_name(_user_id, _app_id), do: nil

  # The caller's tenant from their session (mirrors ApiGatewayWeb user_controller's session_app/1).
  defp session_app(session), do: Map.get(session, :app_id)

  # Call maps arrive atom-keyed (in-process CallStore) or string-keyed (HTTP adapter) — read either.
  defp cget(call, key), do: Map.get(call, key) || Map.get(call, to_string(key))

  # Opaque base64 keyset cursor over "created_at|id" — the SAME encoding the webhook-deliveries and
  # event-outbox lists use. Malformed input degrades to page one, never a 500.
  defp decode_cursor(cursor) when is_binary(cursor) and cursor != "" do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [ts, id] <- String.split(decoded, "|", parts: 2) do
      {ts, id}
    else
      _ -> {nil, nil}
    end
  end

  defp decode_cursor(_), do: {nil, nil}

  defp encode_cursor(nil), do: nil

  defp encode_cursor(next) when is_map(next) do
    ts = cget(next, :ts)
    id = cget(next, :id)

    if is_binary(ts) and is_binary(id),
      do: Base.url_encode64("#{ts}|#{id}", padding: false),
      else: nil
  end

  defp encode_cursor(_), do: nil
end
