defmodule ApiGatewayWeb.CallController do
  @moduledoc """
  Phase-1 calling — LiveKit access tokens. Mints a room-scoped LiveKit JWT for the authenticated user so
  the client can join the SFU. Slice 1 accepts a room name directly; call-row validation (that the user is
  a participant of that call) arrives in a later slice.
  """
  use ApiGatewayWeb, :controller

  require Logger

  alias ApiGatewayWeb.ErrorResponse

  # GET /api/v1/calls → { "calls": [ …, counterpart_id, counterpart_name ] } for the current user.
  # Call history (both sides), newest first — served from conversation_service's CallStore. Each row is
  # enriched server-side with the OTHER party's display name (batched, one profile lookup per unique id);
  # the avatar is resolved client-side via the shared cached useUserProfile hook (same as every chat row).
  # DB flag off (`{:error, :call_unavailable}`) or any read failure → 200 { calls: [] } (never a 500).
  def index(conn, _params) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}) do
      calls =
        case SharedInfra.ConversationClient.list_calls_for_user(%{"user_id" => session.user_id}) do
          {:ok, %{calls: calls}} when is_list(calls) -> calls
          {:ok, %{"calls" => calls}} when is_list(calls) -> calls
          _ -> []
        end

      json(conn, %{calls: enrich(calls, session.user_id, session_app(session))})
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
         {:ok, call} <- fetch_call(call_id),
         :ok <- ensure_callee(call, session.user_id) do
      decline_ringing_call(conn, call, call_id)
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
      kind when kind in ["group", "link"] ->
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
      "status" => cget(call, :status),
      "created_at" => cget(call, :created_at),
      "answered_at" => cget(call, :answered_at),
      "ended_at" => cget(call, :ended_at),
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
end
