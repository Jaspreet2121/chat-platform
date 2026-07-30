defmodule ApiGatewayWeb.V1.CallController do
  @moduledoc """
  Public `/v1` call surface (V1a token/status + V1b lifecycle) — LiveKit token, call status, direct-call
  start/end, and call-links for an integrator's END-USER SDK. Requires the end-user JWT actor
  (`v1_actor == :end_user`); a secret-key/app actor is rejected (403 `v1.end_user_only`, the inverse of the
  webhook secret-key guard). The first-party internal `/api/v1/calls` + `/api/v1/call-links` surfaces are
  untouched.

  TENANT ISOLATION: neither `calls` nor `call_links` carries an app_id — scope rides on the fact that every
  `user_id` was created per `(app_id, external_id)` (AuthClient). So:
    * a call's seats belong to exactly one app → authorizing "this user is a seat" scopes to the caller's app;
    * a call-link's `creator_id` belongs to exactly one app → a link is this app's iff its creator resolves
      within `v1_app_id` (`AuthClient.resolve_user_external_id`).
  V1Auth resolves `v1_user_id` WITHIN `v1_app_id`. Cross-tenant access is impossible and surfaces as 404
  (fail closed, never an existence reveal).

  external_id BOUNDARY: integrators refer to their users by their OWN `external_id`. Inbound ids are resolved
  to internal user_ids via `AuthClient.lookup_external_user` (resolve-ONLY — a callee is a reference, never a
  provisioning site); any user id we RETURN is mapped back to `external_id` via
  `AuthClient.resolve_user_external_id` — internal user_ids never cross the /v1 boundary.

  Reuses the same CallStore boundary the internal flows use (create_call / mark_call_ended /
  leave_group_call / create_call_link / get_call_link / join_call_link / get_call / call_participant? /
  get_call_with_participants) + LiveKitToken — no reimplementation.
  """
  use ApiGatewayWeb, :controller

  require Logger

  alias ApiGatewayWeb.ErrorResponse

  # POST /v1/calls  { callee_external_id, type: "voice"|"video" } — start a direct call. Resolves the callee
  # within v1_app_id, creates the ringing call via the shared boundary, mints the caller's LiveKit token.
  # → { call_id, room, type, url, token }.
  def create(conn, params) do
    app_id = conn.assigns[:v1_app_id]

    with :ok <- require_end_user(conn),
         {:ok, type} <- fetch_type(params),
         {:ok, callee_ext} <- fetch_nonempty(params, "callee_external_id"),
         # LOOKUP, not resolve-or-create: a callee is a REFERENCE to an existing user, not a provisioning
         # site. Previously a bogus callee_external_id CREATED an inert user row and "rang" nobody — a
         # deliberate BEHAVIOUR CHANGE: an unknown callee is now 404 (the same opaque not-found the rest of
         # /v1 uses). JIT creation still happens where it belongs (message sender / media owner /
         # conversation participants).
         {:ok, %{} = callee} <-
           SharedInfra.AuthClient.lookup_external_user(%{"app_id" => app_id, "external_id" => callee_ext}),
         callee_id = cget(callee, :user_id),
         :ok <- refute_self(conn.assigns.v1_user_id, callee_id),
         {:ok, call} <-
           SharedInfra.ConversationClient.create_call(%{
             "caller_id" => conn.assigns.v1_user_id,
             "callee_id" => callee_id,
             "type" => type
           }),
         room = cget(call, :room_name),
         {:ok, jwt} <-
           SharedInfra.LiveKitToken.create(conn.assigns.v1_user_id, room, name: conn.assigns.v1_user_id) do
      # RING THE CALLEE + arm the ring timeout — the two things the socket invite does that this path didn't,
      # which left SDK-initiated calls ringing nobody, forever. Fire-and-forget: never fails the create.
      ring_and_arm_timeout(app_id, call, conn.assigns.v1_user_id, callee_id)

      json(conn, %{
        call_id: cget(call, :id),
        room: room,
        type: cget(call, :type),
        url: SharedInfra.LiveKitToken.url(),
        token: jwt
      })
    else
      {:error, :app_only} -> app_only(conn)
      {:error, :invalid_type} -> ErrorResponse.invalid_request(conn, "v1.invalid_request")
      {:error, :missing} -> ErrorResponse.invalid_request(conn, "v1.invalid_request")
      {:error, :self_call} -> ErrorResponse.invalid_request(conn, "v1.invalid_request")
      # Unknown callee_external_id → opaque 404 (no existence reveal, no row created).
      {:error, :user_not_found} -> not_found(conn)
      {:error, :livekit_not_configured} -> ErrorResponse.service_unavailable(conn, "v1.unavailable")
      _ -> ErrorResponse.service_unavailable(conn, "v1.unavailable")
    end
  end

  # POST /v1/calls/:id/accept — the CALLEE answers a ringing direct call. Flips it to `accepted` (which emits
  # the `call.started` webhook via the shared CallStore path, 21811e2) and broadcasts `call:accepted` to the
  # CALLER so their ring resolves and they get the room. The callee then mints a token via POST .../token.
  # → { call_id, room, status: "accepted" }.
  def accept(conn, %{"id" => call_id}) when is_binary(call_id) and call_id != "" do
    respond_to_ring(conn, call_id, :accept)
  end

  def accept(conn, _params), do: ErrorResponse.invalid_request(conn, "v1.invalid_request")

  # POST /v1/calls/:id/reject — the CALLEE declines a ringing direct call. Flips it to `declined` (emits the
  # `call.declined` webhook) and broadcasts `call:rejected` to the CALLER. → { call_id, status: "declined" }.
  def reject(conn, %{"id" => call_id}) when is_binary(call_id) and call_id != "" do
    respond_to_ring(conn, call_id, :reject)
  end

  def reject(conn, _params), do: ErrorResponse.invalid_request(conn, "v1.invalid_request")

  # POST /v1/calls/:id/token — mint a LiveKit token so the end-user can join call :id (they must be a seat).
  # Not authorized / cross-tenant / missing → 404.
  def token(conn, %{"id" => call_id}) when is_binary(call_id) and call_id != "" do
    with :ok <- require_end_user(conn),
         {:ok, call} <- authorized_call(call_id, conn.assigns.v1_user_id),
         room when is_binary(room) and room != "" <- cget(call, :room_name),
         {:ok, jwt} <-
           SharedInfra.LiveKitToken.create(conn.assigns.v1_user_id, room, name: conn.assigns.v1_user_id) do
      json(conn, %{url: SharedInfra.LiveKitToken.url(), token: jwt})
    else
      {:error, :app_only} -> app_only(conn)
      {:error, :livekit_not_configured} -> ErrorResponse.service_unavailable(conn, "v1.unavailable")
      _ -> not_found(conn)
    end
  end

  def token(conn, _params), do: ErrorResponse.invalid_request(conn, "v1.invalid_request")

  # POST /v1/calls/:id/end — end (direct) or leave (group/link) a call the caller is a seat of.
  # Cross-tenant / non-seat / missing → 404.
  def end_call(conn, %{"id" => call_id}) when is_binary(call_id) and call_id != "" do
    with :ok <- require_end_user(conn),
         {:ok, call} <- authorized_call(call_id, conn.assigns.v1_user_id),
         {:ok, status} <- terminate(call, call_id, conn.assigns.v1_user_id) do
      # The socket hangup's SECOND half, previously missing here: tell the OTHER party (call:ended), so
      # their client resolves instead of sitting "connected" forever. Direct calls only ("ended") — a
      # group/link leave has its own lifecycle events. Fire-and-forget via the same helper accept/reject use.
      if status == "ended", do: notify_peer_ended(call, call_id, conn.assigns.v1_user_id)
      json(conn, %{status: status})
    else
      {:error, :app_only} -> app_only(conn)
      {:error, :unavailable} -> ErrorResponse.service_unavailable(conn, "v1.unavailable")
      _ -> not_found(conn)
    end
  end

  def end_call(conn, _params), do: ErrorResponse.invalid_request(conn, "v1.invalid_request")

  # GET /v1/calls/:id — call status (participants as EXTERNAL ids), scoped: the caller must be a seat.
  # Cross-tenant / missing → 404.
  def show(conn, %{"id" => call_id}) when is_binary(call_id) and call_id != "" do
    with :ok <- require_end_user(conn),
         {:ok, call} <- authorized_call(call_id, conn.assigns.v1_user_id) do
      json(conn, present_status(call, call_id, conn.assigns[:v1_app_id]))
    else
      {:error, :app_only} -> app_only(conn)
      _ -> not_found(conn)
    end
  end

  def show(conn, _params), do: ErrorResponse.invalid_request(conn, "v1.invalid_request")

  # POST /v1/call-links  { type, require_approval } — create a reusable call link (creator = v1_user_id).
  # → { link_id, type, require_approval, path }.
  def create_link(conn, params) do
    with :ok <- require_end_user(conn),
         {:ok, type} <- fetch_type(params),
         {:ok, %{link: link}} <-
           SharedInfra.ConversationClient.create_call_link(%{
             "creator_id" => conn.assigns.v1_user_id,
             "type" => type,
             "require_approval" => truthy(params["require_approval"])
           }) do
      json(conn, %{
        link_id: cget(link, :id),
        type: cget(link, :type),
        require_approval: cget(link, :require_approval),
        path: "/call/" <> to_string(cget(link, :id))
      })
    else
      {:error, :app_only} -> app_only(conn)
      {:error, :invalid_type} -> ErrorResponse.invalid_request(conn, "v1.invalid_request")
      _ -> ErrorResponse.service_unavailable(conn, "v1.unavailable")
    end
  end

  # POST /v1/call-links/:id/join — join a link (actor = v1_user_id). On "joined" → include a token so the
  # SDK connects; on "pending_approval" → no token (host approval flow). Link of another app → 404.
  def join_link(conn, %{"id" => link_id}) when is_binary(link_id) and link_id != "" do
    with :ok <- require_end_user(conn),
         {:ok, _link} <- scoped_link(link_id, conn.assigns[:v1_app_id]),
         {:ok, result} <-
           SharedInfra.ConversationClient.join_call_link(%{
             "link_id" => link_id,
             "user_id" => conn.assigns.v1_user_id
           }) do
      json(conn, join_payload(conn, result))
    else
      {:error, :app_only} -> app_only(conn)
      {:error, :unavailable} -> ErrorResponse.service_unavailable(conn, "v1.unavailable")
      _ -> not_found(conn)
    end
  end

  def join_link(conn, _params), do: ErrorResponse.invalid_request(conn, "v1.invalid_request")

  # GET /v1/call-links/:id — link info, scoped by creator ∈ app. Cross-tenant / inactive / missing → 404.
  def show_link(conn, %{"id" => link_id}) when is_binary(link_id) and link_id != "" do
    with :ok <- require_end_user(conn),
         {:ok, link} <- scoped_link(link_id, conn.assigns[:v1_app_id]) do
      json(conn, %{
        link_id: cget(link, :id),
        type: cget(link, :type),
        require_approval: cget(link, :require_approval),
        active: cget(link, :active)
      })
    else
      {:error, :app_only} -> app_only(conn)
      _ -> not_found(conn)
    end
  end

  def show_link(conn, _params), do: ErrorResponse.invalid_request(conn, "v1.invalid_request")

  # --- helpers -----------------------------------------------------------------------------------

  # /v1 calls require the END-USER JWT (has a user_id). A secret-key/app actor has no user → reject.
  defp require_end_user(conn) do
    if conn.assigns[:v1_actor] == :end_user and is_binary(conn.assigns[:v1_user_id]),
      do: :ok,
      else: {:error, :app_only}
  end

  # Ring the callee (call:incoming + web push) and arm the ring timeout for a /v1-created call. Both reuse
  # the SAME `RealtimeGateway.CallSignaling` implementations the socket invite uses — one ring payload, one
  # timeout path — via the endpoint the socket is mounted on (one endpoint, one PubSub).
  #
  # Fire-and-forget in detached tasks: a resolve/broadcast/push hiccup must never fail the create (the caller
  # already has their room + token), and the 35s timer must outlive this request process (Task.start is
  # unlinked). The timeout calls the same `ring_timeout` the socket path uses: it re-checks status under way,
  # so an accept/reject landing first makes it a no-op, and a fired timeout marks the call missed, writes the
  # missed-call message (no-op here — /v1 calls carry no conversation), broadcasts call:missed to both
  # parties, and emits the call.missed webhook via the shared CallStore transition.
  #
  # HONEST LIMITATION: this timer lives in THIS node's memory. A deploy/restart between create and +35s kills
  # it, leaving the call `ringing` forever — nothing else marks stale ringing calls missed (verified: no
  # sweep exists). The durable fix is a periodic stale-ringing sweep (the known "ghost-call auto-close"
  # follow-up), deliberately not built in this slice.
  defp ring_and_arm_timeout(app_id, call, caller_id, callee_id) do
    call_id = cget(call, :id)

    Task.start(fn ->
      try do
        RealtimeGateway.CallSignaling.ring_callee(ApiGatewayWeb.Endpoint, app_id, %{
          call_id: call_id,
          room: cget(call, :room_name),
          caller_id: caller_id,
          callee_id: callee_id,
          type: cget(call, :type),
          conversation_id: cget(call, :conversation_id)
        })
      rescue
        # Never fail the create — but never vanish either (the callee simply wouldn't ring).
        error -> Logger.error("v1 call ring failed for #{call_id}: #{Exception.message(error)}")
      end
    end)

    Task.start(fn ->
      Process.sleep(RealtimeGateway.CallSignaling.ring_timeout_ms())
      # ring_timeout rescues internally; a still-ringing call → missed (idempotent re-check inside).
      RealtimeGateway.CallSignaling.ring_timeout(call_id, ApiGatewayWeb.Endpoint)
    end)

    :ok
  end

  # accept/reject share everything but the transition, the caller event, and the response — so one path.
  defp respond_to_ring(conn, call_id, action) do
    with :ok <- require_end_user(conn),
         {:ok, call} <- callee_ringing_call(call_id, conn.assigns[:v1_user_id]),
         {:ok, _} <- transition_for(action, call_id) do
      # Resolve the caller's ring only AFTER the state actually changed — never announce an accept that
      # didn't commit. Fire-and-forget: the response must not fail if PubSub hiccups.
      notify_caller(action, cget(call, :caller_id), call_id, cget(call, :room_name))
      json(conn, ring_response(action, call_id, cget(call, :room_name)))
    else
      {:error, :app_only} ->
        app_only(conn)

      # The callee owns this call but it is no longer ringing (already answered / ended / cancelled). 409, NOT
      # 404: the legit callee should learn "too late", and we must never let a second transition un-end it or
      # re-emit the webhook. (A NON-callee never reaches this branch — see callee_ringing_call.)
      {:error, :not_ringing} ->
        ErrorResponse.conflict(conn, "v1.call_not_ringing", "This call is no longer ringing")

      # The status transition failed at the service (e.g. the call vanished in a race) — transient.
      {:error, :unavailable} ->
        ErrorResponse.service_unavailable(conn, "v1.unavailable")

      # Not the callee / not a direct call / cross-tenant / missing → 404, no existence reveal.
      _ ->
        not_found(conn)
    end
  end

  # Authorize a ring response: the acting user must be THIS direct call's callee, and it must still be
  # ringing. The order matters — the callee check runs BEFORE the status check, so a non-callee only ever
  # gets :not_found (never a 409 that would reveal the call's state). Comparing v1_user_id (resolved within
  # v1_app_id) to callee_id is also the tenant seal: a cross-tenant user's internal id can't match.
  defp callee_ringing_call(call_id, user_id) do
    with {:ok, call} <- SharedInfra.ConversationClient.get_call(%{"call_id" => call_id}),
         :callee <- ring_role(call, user_id),
         "ringing" <- cget(call, :status) do
      {:ok, call}
    else
      # Reached ONLY after the callee check passed (the status wasn't "ringing") → a real conflict.
      status when is_binary(status) -> {:error, :not_ringing}
      # get_call failed, or ring_role returned :not_callee / :not_direct → opaque 404.
      _ -> {:error, :not_found}
    end
  end

  # accept/reject are DIRECT 1:1 verbs. A group/link call answers via its own join flow, and its "callee_id"
  # isn't the single answerer — so anything but a direct call where user_id IS the callee is rejected here.
  defp ring_role(call, user_id) do
    cond do
      (cget(call, :kind) || "direct") != "direct" -> :not_direct
      is_binary(user_id) and user_id == cget(call, :callee_id) -> :callee
      true -> :not_callee
    end
  end

  # The SAME shared boundary the socket accept/reject uses — the status transition (and its webhook) is
  # identical whether answered via socket or /v1. `expected_status: "ringing"` makes the transition ATOMIC:
  # the callee_ringing_call check above is only a fast-path 409, and this closes the check-then-act race
  # (two concurrent accepts, or a cancel racing an accept) by re-checking the status under a row lock in the
  # service. A lost race → :call_conflict → the same 409 as the fast-path.
  defp transition_for(:accept, call_id),
    do:
      normalize_transition(
        SharedInfra.ConversationClient.mark_call_answered(%{
          "call_id" => call_id,
          "expected_status" => "ringing"
        })
      )

  defp transition_for(:reject, call_id),
    do:
      normalize_transition(
        SharedInfra.ConversationClient.mark_call_declined(%{
          "call_id" => call_id,
          "expected_status" => "ringing"
        })
      )

  defp normalize_transition({:ok, _} = ok), do: ok
  # The atomic guard lost the race (the call left "ringing" under the lock) → the same conflict the fast-path
  # returns.
  defp normalize_transition({:error, :call_conflict}), do: {:error, :not_ringing}
  defp normalize_transition(_), do: {:error, :unavailable}

  # Resolve the CALLER's ring: call:accepted hands them the room; call:rejected just tells them it's off.
  # Reaches the caller's SDK because RealtimeGateway.UserSocket is mounted on ApiGatewayWeb.Endpoint (one
  # endpoint, one PubSub) — the same path conversation_created / message_created fan out on.
  defp notify_caller(:accept, caller_id, call_id, room),
    do: broadcast_caller(caller_id, "call:accepted", %{call_id: call_id, room: room})

  defp notify_caller(:reject, caller_id, call_id, _room),
    do: broadcast_caller(caller_id, "call:rejected", %{call_id: call_id})

  defp broadcast_caller(caller_id, event, payload) when is_binary(caller_id) and caller_id != "" do
    Task.start(fn ->
      try do
        ApiGatewayWeb.Endpoint.broadcast("user:" <> caller_id, event, payload)
      rescue
        # Fire-and-forget must never fail the response — but a silent drop would leave the caller ringing
        # until the 35s timeout, so it must not vanish either.
        error -> Logger.error("call #{event} broadcast to caller failed: #{Exception.message(error)}")
      end
    end)

    :ok
  end

  defp broadcast_caller(_caller_id, _event, _payload), do: :ok

  # Mirror of the socket hangup's peer pick: the actor's counterpart on the call row.
  defp notify_peer_ended(call, call_id, actor_user_id) do
    other =
      if actor_user_id == cget(call, :caller_id),
        do: cget(call, :callee_id),
        else: cget(call, :caller_id)

    broadcast_caller(other, "call:ended", %{call_id: call_id})
  end

  defp ring_response(:accept, call_id, room), do: %{call_id: call_id, room: room, status: "accepted"}
  defp ring_response(:reject, call_id, _room), do: %{call_id: call_id, status: "declined"}

  # Fetch the call ONLY if `user_id` is a seat of it — this IS the tenant seal (see @moduledoc). Any failure
  # (missing / cross-tenant / not authorized) collapses to :not_found → 404, no existence reveal.
  defp authorized_call(call_id, user_id) do
    with {:ok, call} <- SharedInfra.ConversationClient.get_call(%{"call_id" => call_id}),
         true <- seat?(call, call_id, user_id) do
      {:ok, call}
    else
      _ -> {:error, :not_found}
    end
  end

  # Mirrors the internal call_controller's authorize check (kept separate so /api/v1/calls stays UNTOUCHED):
  # group/link calls authorize on a participant row; direct calls on caller/callee.
  defp seat?(call, call_id, user_id) do
    case cget(call, :kind) || "direct" do
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

  # End a direct call (both seats share one row → mark ended) or leave a group/link call (per-participant).
  defp terminate(call, call_id, user_id) do
    case cget(call, :kind) || "direct" do
      kind when kind in ["group", "link"] ->
        case SharedInfra.ConversationClient.leave_group_call(%{"call_id" => call_id, "user_id" => user_id}) do
          {:ok, _} -> {:ok, "left"}
          _ -> {:error, :unavailable}
        end

      _ ->
        case SharedInfra.ConversationClient.mark_call_ended(%{"call_id" => call_id}) do
          {:ok, _} -> {:ok, "ended"}
          _ -> {:error, :unavailable}
        end
    end
  end

  # Load a call link and confirm it belongs to this app (its creator resolves within v1_app_id). Missing /
  # inactive / cross-tenant → :not_found.
  defp scoped_link(link_id, app_id) do
    with {:ok, %{link: link}} <- SharedInfra.ConversationClient.get_call_link(%{"link_id" => link_id}),
         {:ok, _} <-
           SharedInfra.AuthClient.resolve_user_external_id(%{
             "app_id" => app_id,
             "user_id" => cget(link, :creator_id)
           }) do
      {:ok, link}
    else
      _ -> {:error, :not_found}
    end
  end

  # Shape a join result. "joined" → mint a token for the caller so the SDK connects; "pending_approval" →
  # no room/token (the token endpoint 403s until the host approves).
  defp join_payload(conn, result) do
    call = cget(result, :call)
    status = cget(result, :status)
    room = cget(result, :room)

    base = %{
      status: status,
      call_id: cget(call, :id),
      type: cget(result, :type),
      require_approval: cget(result, :require_approval),
      is_host: cget(result, :is_host)
    }

    with "joined" <- status,
         true <- is_binary(room) and room != "",
         {:ok, jwt} <-
           SharedInfra.LiveKitToken.create(conn.assigns.v1_user_id, room, name: conn.assigns.v1_user_id) do
      Map.merge(base, %{room: room, url: SharedInfra.LiveKitToken.url(), token: jwt})
    else
      _ -> base
    end
  end

  defp present_status(call, call_id, app_id) do
    %{
      id: cget(call, :id),
      kind: cget(call, :kind) || "direct",
      status: cget(call, :status),
      type: cget(call, :type),
      participants: external_ids(participant_user_ids(call, call_id), app_id)
    }
  end

  # Direct calls have no participant rows → the seats are caller + callee. Group/link calls read the
  # group_call_participants rows. Returns INTERNAL user_ids (mapped to external_id before leaving /v1).
  defp participant_user_ids(call, call_id) do
    case cget(call, :kind) || "direct" do
      kind when kind in ["group", "link"] ->
        case SharedInfra.ConversationClient.get_call_with_participants(%{"call_id" => call_id}) do
          {:ok, result} ->
            (cget(result, :participants) || []) |> Enum.map(&cget(&1, :user_id)) |> Enum.reject(&is_nil/1)

          _ ->
            []
        end

      _ ->
        Enum.filter([cget(call, :caller_id), cget(call, :callee_id)], &is_binary/1)
    end
  end

  # Map internal user_ids → the integrator's external_ids within the app; drop any that don't resolve
  # (they aren't this app's users). Internal user_ids never cross the /v1 boundary.
  defp external_ids(user_ids, app_id) do
    user_ids
    |> Enum.map(&external_id_for(app_id, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp external_id_for(app_id, user_id) when is_binary(app_id) and is_binary(user_id) do
    case SharedInfra.AuthClient.resolve_user_external_id(%{"app_id" => app_id, "user_id" => user_id}) do
      {:ok, res} -> cget(res, :external_id)
      _ -> nil
    end
  end

  defp external_id_for(_app_id, _user_id), do: nil

  defp fetch_type(%{"type" => type}) when type in ["voice", "video"], do: {:ok, type}
  defp fetch_type(_), do: {:error, :invalid_type}

  defp fetch_nonempty(params, key) do
    case Map.get(params, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, :missing}
    end
  end

  defp refute_self(caller_id, callee_id) do
    if is_binary(callee_id) and callee_id != caller_id, do: :ok, else: {:error, :self_call}
  end

  defp truthy(v), do: v in [true, "true", "1", "yes"]

  defp app_only(conn),
    do: ErrorResponse.forbidden(conn, "v1.end_user_only", "This endpoint requires an end-user token")

  defp not_found(conn), do: ErrorResponse.not_found(conn, "v1.not_found", "Not found")

  # Maps arrive atom-keyed (in-process) or string-keyed (HTTP adapter) — read either. Nil-safe.
  defp cget(nil, _key), do: nil
  # Presence-based (SharedInfra.Attrs): reads require_approval (a boolean) — `||` dropped a stored false.
  defp cget(map, key) when is_map(map), do: SharedInfra.Attrs.get(map, key)
  defp cget(_map, _key), do: nil
end
