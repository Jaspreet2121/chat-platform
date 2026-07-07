defmodule ApiGatewayWeb.CallController do
  @moduledoc """
  Phase-1 calling — LiveKit access tokens. Mints a room-scoped LiveKit JWT for the authenticated user so
  the client can join the SFU. Slice 1 accepts a room name directly; call-row validation (that the user is
  a participant of that call) arrives in a later slice.
  """
  use ApiGatewayWeb, :controller

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

      json(conn, %{calls: enrich(calls, session.user_id)})
    else
      _ -> ErrorResponse.unauthorized(conn, "auth.unauthorized", "Invalid or missing session")
    end
  end

  # POST /api/v1/calls/token  { "room": "<room_name>" }
  # → { "url": "wss://…", "token": "<livekit jwt>" } for the current user + room.
  def token(conn, %{"room" => room}) when is_binary(room) and room != "" do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, jwt} <- SharedInfra.LiveKitToken.create(session.user_id, room, name: session.user_id) do
      json(conn, %{url: SharedInfra.LiveKitToken.url(), token: jwt})
    else
      {:error, :livekit_not_configured} ->
        ErrorResponse.service_unavailable(conn, "calls.unavailable")

      _ ->
        ErrorResponse.unauthorized(conn, "auth.unauthorized", "Invalid or missing session")
    end
  end

  def token(conn, _params), do: ErrorResponse.invalid_request(conn, "calls.room_required")

  defp authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token = authorization] when token != "" -> {:ok, authorization}
      _ -> {:error, :session_invalid}
    end
  end

  # Normalize each call to a stable string-keyed shape + the counterpart id, then batch-enrich names
  # (one profile lookup per UNIQUE counterpart, not per row).
  defp enrich(calls, me) do
    rows = Enum.map(calls, &present_call(&1, me))

    names =
      rows
      |> Enum.map(& &1["counterpart_id"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Map.new(fn id -> {id, resolve_name(id)} end)

    Enum.map(rows, fn row -> Map.put(row, "counterpart_name", Map.get(names, row["counterpart_id"])) end)
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
  defp resolve_name(user_id) when is_binary(user_id) and user_id != "" do
    case SharedInfra.UserClient.get_public_profile(%{"user_id" => user_id}) do
      {:ok, profile} ->
        name = Map.get(profile, :display_name) || Map.get(profile, "display_name")
        if is_binary(name) and name != "", do: name, else: nil

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp resolve_name(_), do: nil

  # Call maps arrive atom-keyed (in-process CallStore) or string-keyed (HTTP adapter) — read either.
  defp cget(call, key), do: Map.get(call, key) || Map.get(call, to_string(key))
end
