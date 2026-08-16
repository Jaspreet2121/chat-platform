defmodule ApiGatewayWeb.CallLinkController do
  @moduledoc """
  Call links (L1) — REST for the reusable, WhatsApp-style call link. Registered users only (session-gated,
  same as CallController). Create a link, read a link's metadata (join screen), and join a link (find-or-
  create a conversation-less "link" call + a joined participant row). The client then fetches a LiveKit token
  for the returned room via `/api/v1/calls/token` (authorize_call handles kind="link").

  Approval enforcement is L3 — L1 returns `require_approval` but lets everyone join.
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  # POST /api/v1/call-links  { "type": "voice"|"video", "require_approval": bool } → { "link": {...} }
  def create(conn, params) do
    with {:ok, session} <- current_session(conn),
         {:ok, type} <- fetch_type(params),
         {:ok, %{link: link}} <-
           SharedInfra.ConversationClient.create_call_link(%{
             "creator_id" => session.user_id,
             "type" => type,
             "require_approval" => params["require_approval"] == true
           }) do
      json(conn, %{link: present_link(link)})
    else
      {:error, :invalid_type} ->
        ErrorResponse.invalid_request(conn, "call_link.invalid_type")

      {:error, :session_invalid} ->
        session_invalid(conn)

      {:error, :conversation_unavailable} ->
        ErrorResponse.service_unavailable(conn, "call_link.unavailable")

      _ ->
        ErrorResponse.invalid_request(conn, "call_link.create_failed")
    end
  end

  # GET /api/v1/call-links/:id → { "link": {...} } — metadata for the join screen (auth required).
  def show(conn, %{"id" => id}) when is_binary(id) and id != "" do
    with {:ok, _session} <- current_session(conn),
         {:ok, %{link: link}} <- SharedInfra.ConversationClient.get_call_link(%{"link_id" => id}) do
      json(conn, %{link: present_link(link)})
    else
      {:error, :session_invalid} ->
        session_invalid(conn)

      {:error, :link_not_found} ->
        ErrorResponse.not_found(conn, "call_link.not_found", "Link not found")

      _ ->
        ErrorResponse.not_found(conn, "call_link.not_found", "Link not found")
    end
  end

  def show(conn, _params), do: ErrorResponse.invalid_request(conn, "call_link.invalid_request")

  # POST /api/v1/call-links/:id/join → { call_id, room, type, require_approval, is_host }
  def join(conn, %{"id" => id}) when is_binary(id) and id != "" do
    with {:ok, session} <- current_session(conn),
         {:ok, result} <-
           SharedInfra.ConversationClient.join_call_link(%{
             "link_id" => id,
             "user_id" => session.user_id,
             # 097: the session's tenant stamps a freshly-created link call (only the FIRST joiner creates).
             "app_id" => Map.get(session, :app_id)
           }) do
      call = cget(result, :call)

      # status is "joined" (host / no-approval → room present) or "pending_approval" (approval-required
      # non-host → NO room; the client waits, then connects on the call:link_approved signal — L3b).
      json(conn, %{
        status: cget(result, :status),
        call_id: cget(call, :id),
        room: cget(result, :room),
        type: cget(result, :type),
        require_approval: cget(result, :require_approval),
        is_host: cget(result, :is_host)
      })
    else
      {:error, :session_invalid} ->
        session_invalid(conn)

      {:error, :link_not_found} ->
        ErrorResponse.not_found(conn, "call_link.not_found", "Link not found")

      {:error, :conversation_unavailable} ->
        ErrorResponse.service_unavailable(conn, "call_link.unavailable")

      _ ->
        ErrorResponse.invalid_request(conn, "call_link.join_failed")
    end
  end

  def join(conn, _params), do: ErrorResponse.invalid_request(conn, "call_link.invalid_request")

  # --- helpers -----------------------------------------------------------------------------------

  defp current_session(conn) do
    with {:ok, authorization} <- authorization_header(conn) do
      SharedInfra.AuthClient.current_session(%{"authorization" => authorization})
    end
  end

  defp authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token = authorization] when token != "" -> {:ok, authorization}
      _ -> {:error, :session_invalid}
    end
  end

  defp fetch_type(%{"type" => type}) when type in ["voice", "video"], do: {:ok, type}
  defp fetch_type(_), do: {:error, :invalid_type}

  # Present a link map (atom-keyed in-process / string-keyed HTTP adapter) → the public shape.
  defp present_link(link) do
    %{
      id: cget(link, :id),
      type: cget(link, :type),
      require_approval: cget(link, :require_approval),
      active: cget(link, :active)
    }
  end

  defp session_invalid(conn),
    do: ErrorResponse.unauthorized(conn, "auth.unauthorized", "Invalid or missing session")

  # Presence-based (SharedInfra.Attrs): this map carries BOOLEANS (require_approval / active / is_host),
  # and the `||` idiom serialized a stored false as null.
  defp cget(map, key), do: SharedInfra.Attrs.get(map, key)
end
