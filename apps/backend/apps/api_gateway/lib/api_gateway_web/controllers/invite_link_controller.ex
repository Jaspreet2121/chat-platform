defmodule ApiGatewayWeb.InviteLinkController do
  @moduledoc """
  Group invite links (077) — REST for the shareable, WhatsApp-style "join a group via link". Session-gated
  (first-party). Management (create / revoke / reset) is conversation-scoped and OWNER-ONLY; preview + join
  are code-scoped.

    POST   /api/v1/conversations/:conversation_id/invite-link        → { code, url }  (mint or existing)
    DELETE /api/v1/conversations/:conversation_id/invite-link        → { revoked: true }
    POST   /api/v1/conversations/:conversation_id/invite-link/reset   → { code, url }  (revoke + mint)
    GET    /api/v1/invite-links/:code                                 → { name, avatar_url, member_count }
    POST   /api/v1/invite-links/:code/join                            → { status, conversation_id, role }

  A join goes through the SAME participant path as an owner add — after a fresh join we fire the identical
  `conversation_updated` `:participant` frame, so the joiner's inbox row / unread / fan-out match exactly.
  Unknown / revoked code → 404 (never reveals a code once existed); non-owner → 403 conversation.not_owner;
  a REMOVED user rejoining → 403 invite_link.removed.
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  # POST /conversations/:conversation_id/invite-link
  def create_link(conn, %{"conversation_id" => conversation_id}) do
    with {:ok, session} <- current_session(conn),
         {:ok, result} <-
           SharedInfra.ConversationClient.create_group_invite_link(%{
             "conversation_id" => conversation_id,
             "actor_user_id" => session.user_id
           }) do
      json(conn, link_payload(result))
    else
      error -> handle_error(conn, error)
    end
  end

  # DELETE /conversations/:conversation_id/invite-link
  def revoke_link(conn, %{"conversation_id" => conversation_id}) do
    with {:ok, session} <- current_session(conn),
         {:ok, _result} <-
           SharedInfra.ConversationClient.revoke_group_invite_link(%{
             "conversation_id" => conversation_id,
             "actor_user_id" => session.user_id
           }) do
      json(conn, %{revoked: true})
    else
      error -> handle_error(conn, error)
    end
  end

  # POST /conversations/:conversation_id/invite-link/reset
  def reset_link(conn, %{"conversation_id" => conversation_id}) do
    with {:ok, session} <- current_session(conn),
         {:ok, result} <-
           SharedInfra.ConversationClient.reset_group_invite_link(%{
             "conversation_id" => conversation_id,
             "actor_user_id" => session.user_id
           }) do
      json(conn, link_payload(result))
    else
      error -> handle_error(conn, error)
    end
  end

  # GET /invite-links/:code — the join preview (session-gated, exactly {name, avatar_url, member_count}).
  def preview(conn, %{"code" => code}) when is_binary(code) and code != "" do
    with {:ok, session} <- current_session(conn),
         {:ok, result} <-
           SharedInfra.ConversationClient.preview_group_invite_link(%{
             "code" => code,
             "app_id" => session_app(session)
           }) do
      json(conn, %{
        name: cget(result, :name),
        avatar_url:
          preview_avatar_url(cget(result, :group_avatar_media_id), session_app(session)),
        member_count: cget(result, :member_count)
      })
    else
      error -> handle_error(conn, error)
    end
  end

  def preview(conn, _params),
    do: ErrorResponse.invalid_request(conn, "invite_link.invalid_request")

  # POST /invite-links/:code/join
  def join(conn, %{"code" => code}) when is_binary(code) and code != "" do
    with {:ok, session} <- current_session(conn),
         {:ok, result} <-
           SharedInfra.ConversationClient.join_group_invite_link(%{
             "code" => code,
             "user_id" => session.user_id,
             "app_id" => session_app(session)
           }) do
      status = cget(result, :status)
      conversation_id = cget(result, :conversation_id)

      # A FRESH join changed the participant set → fire the SAME :participant frame an owner add fires (fans
      # to every member INCLUDING the joiner, which is how the group appears in their inbox live). An
      # already-member join changed nothing → stay silent.
      if status == "joined" do
        ApiGatewayWeb.ConversationBroadcast.broadcast_updated(
          conversation_id,
          session.user_id,
          :participant
        )
      end

      json(conn, %{status: status, conversation_id: conversation_id, role: cget(result, :role)})
    else
      error -> handle_error(conn, error)
    end
  end

  def join(conn, _params), do: ErrorResponse.invalid_request(conn, "invite_link.invalid_request")

  # --- helpers -----------------------------------------------------------------------------------

  defp link_payload(result) do
    code = cget(result, :code)
    %{code: code, url: invite_url(code)}
  end

  # The shareable link: WEB_BASE_URL (default https://web.growblic.com) + /join/<code>. Distinct from the
  # phone-invite path (/invite/<code>) so the two features never collide.
  defp invite_url(code) do
    base =
      Application.get_env(:api_gateway, :web_base_url) || System.get_env("WEB_BASE_URL") ||
        "https://web.growblic.com"

    String.trim_trailing(base, "/") <> "/join/" <> code
  end

  # Presign the group avatar for the preview (same purpose assertion as the conversation list/detail). A
  # missing avatar or media error → nil (client falls back to initials). Non-security best-effort.
  defp preview_avatar_url(media_id, app_id) when is_binary(media_id) and is_binary(app_id) do
    case SharedInfra.MediaClient.get_download_url(%{
           "media_id" => media_id,
           "app_id" => app_id,
           "purpose" => "group_avatar"
         }) do
      {:ok, download} -> Map.get(download, :download_url) || Map.get(download, "download_url")
      _ -> nil
    end
  end

  defp preview_avatar_url(_media_id, _app_id), do: nil

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

  defp session_app(session), do: Map.get(session, :app_id)

  defp handle_error(conn, {:error, :session_invalid}),
    do: ErrorResponse.unauthorized(conn, "auth.session_invalid", "Invalid or missing session")

  defp handle_error(conn, {:error, :not_owner}),
    do:
      ErrorResponse.forbidden(
        conn,
        "conversation.not_owner",
        "Only the group owner can manage the invite link"
      )

  defp handle_error(conn, {:error, :removed}),
    do:
      ErrorResponse.forbidden(
        conn,
        "invite_link.removed",
        "You were removed from this group and can't rejoin via link"
      )

  defp handle_error(conn, {:error, :link_not_found}),
    do: ErrorResponse.not_found(conn, "invite_link.not_found", "Invite link not found")

  # A non-group / unknown conversation for the management ops → 404 (nothing revealed about the id).
  defp handle_error(conn, {:error, reason})
       when reason in [:not_a_group, :conversation_not_found],
       do: ErrorResponse.not_found(conn, "conversation.not_found", "Not found")

  defp handle_error(conn, {:error, :conversation_unavailable}),
    do: ErrorResponse.service_unavailable(conn, "invite_link.unavailable")

  defp handle_error(conn, _other),
    do: ErrorResponse.invalid_request(conn, "invite_link.invalid_request")

  defp cget(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end
