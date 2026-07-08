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
  to internal user_ids via `AuthClient.resolve_external_user`; any user id we RETURN is mapped back to
  `external_id` via `AuthClient.resolve_user_external_id` — internal user_ids never cross the /v1 boundary.

  Reuses the same CallStore boundary the internal flows use (create_call / mark_call_ended /
  leave_group_call / create_call_link / get_call_link / join_call_link / get_call / call_participant? /
  get_call_with_participants) + LiveKitToken — no reimplementation.
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  # POST /v1/calls  { callee_external_id, type: "voice"|"video" } — start a direct call. Resolves the callee
  # within v1_app_id, creates the ringing call via the shared boundary, mints the caller's LiveKit token.
  # → { call_id, room, type, url, token }.
  def create(conn, params) do
    app_id = conn.assigns[:v1_app_id]

    with :ok <- require_end_user(conn),
         {:ok, type} <- fetch_type(params),
         {:ok, callee_ext} <- fetch_nonempty(params, "callee_external_id"),
         {:ok, %{} = callee} <-
           SharedInfra.AuthClient.resolve_external_user(%{"app_id" => app_id, "external_id" => callee_ext}),
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
      {:error, :livekit_not_configured} -> ErrorResponse.service_unavailable(conn, "v1.unavailable")
      _ -> ErrorResponse.service_unavailable(conn, "v1.unavailable")
    end
  end

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
  defp cget(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp cget(_map, _key), do: nil
end
