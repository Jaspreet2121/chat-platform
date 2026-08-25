defmodule ApiGatewayWeb.BlockController do
  @moduledoc """
  First-party user blocking. Session-authenticated; the blocker is ALWAYS the session user (never trusted
  from the body).

      POST   /api/v1/blocks          {user_id}  → 204   (block — idempotent)
      DELETE /api/v1/blocks/:user_id            → 204   (unblock — idempotent)
      GET    /api/v1/blocks                      → {blocks: [{user_id, display_name?, avatar_url?, created_at}]}

  Blocking yourself → 400; an unknown user → 404 (no existence leak beyond what by-phone already reveals). The
  relationship + every enforcement point live in conversation-service (ConversationService.Blocks); this is a
  thin session-authed front over the ConversationClient boundary. "Report and block" is two client calls (this
  + POST /reports), never a combined endpoint.
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  def create(conn, %{"user_id" => user_id}) when is_binary(user_id) and user_id != "" do
    with {:ok, session} <- session(conn),
         {:ok, _} <-
           SharedInfra.ConversationClient.block_user(%{
             "blocker_user_id" => session.user_id,
             "blocked_user_id" => user_id
           }) do
      # DATING AUTO-UNMATCH (105): a blocked pair must not stay matched. Best-effort AFTER the
      # block committed (the block never fails on a dating hiccup); every dating read also excludes
      # blocked pairs at store level as the belt behind this.
      ApiGatewayWeb.DatingController.unmatch_on_block(
        session.user_id,
        user_id,
        session_app(session)
      )

      send_resp(conn, :no_content, "")
    else
      {:error, :session_invalid} ->
        unauthorized(conn)

      {:error, :block_self} ->
        ErrorResponse.invalid_request(conn, "blocks.self")

      {:error, :block_unknown_user} ->
        ErrorResponse.not_found(conn, "blocks.user_not_found", "User not found")

      {:error, :conversation_unavailable} ->
        ErrorResponse.service_unavailable(conn, "blocks.unavailable")

      _ ->
        ErrorResponse.invalid_request(conn, "blocks.invalid_request")
    end
  end

  def create(conn, _params), do: ErrorResponse.invalid_request(conn, "blocks.user_id_required")

  def delete(conn, %{"user_id" => user_id}) when is_binary(user_id) and user_id != "" do
    with {:ok, session} <- session(conn),
         {:ok, _} <-
           SharedInfra.ConversationClient.unblock_user(%{
             "blocker_user_id" => session.user_id,
             "blocked_user_id" => user_id
           }) do
      send_resp(conn, :no_content, "")
    else
      {:error, :session_invalid} ->
        unauthorized(conn)

      {:error, :conversation_unavailable} ->
        ErrorResponse.service_unavailable(conn, "blocks.unavailable")

      _ ->
        ErrorResponse.invalid_request(conn, "blocks.invalid_request")
    end
  end

  def delete(conn, _params), do: ErrorResponse.invalid_request(conn, "blocks.user_id_required")

  def index(conn, _params) do
    with {:ok, session} <- session(conn),
         {:ok, result} <-
           SharedInfra.ConversationClient.list_blocks(%{"blocker_user_id" => session.user_id}) do
      blocks = Map.get(result, :blocks) || Map.get(result, "blocks") || []
      json(conn, %{blocks: enrich(blocks, session_app(session))})
    else
      {:error, :session_invalid} ->
        unauthorized(conn)

      {:error, :conversation_unavailable} ->
        ErrorResponse.service_unavailable(conn, "blocks.unavailable")

      _ ->
        json(conn, %{blocks: []})
    end
  end

  # Best-effort enrichment: one public-profile lookup per blocked user for display_name + a presigned avatar
  # (same shape the chat rows use). A lookup miss leaves the row as id + created_at only — the block list still
  # renders. Mirrors the call-history name enrichment.
  defp enrich(blocks, app_id) do
    Enum.map(blocks, fn row ->
      uid = Map.get(row, :user_id) || Map.get(row, "user_id")
      created_at = Map.get(row, :created_at) || Map.get(row, "created_at")
      {display_name, avatar_url} = resolve_profile(uid, app_id)

      %{user_id: uid, created_at: created_at, display_name: display_name, avatar_url: avatar_url}
    end)
  end

  defp resolve_profile(uid, app_id) when is_binary(uid) and is_binary(app_id) do
    case SharedInfra.UserClient.get_public_profile(%{"user_id" => uid, "app_id" => app_id}) do
      {:ok, profile} ->
        name = Map.get(profile, :display_name) || Map.get(profile, "display_name")
        media_id = Map.get(profile, :avatar_media_id) || Map.get(profile, "avatar_media_id")
        {present(name), presign_avatar(media_id, app_id)}

      _ ->
        {nil, nil}
    end
  rescue
    _ -> {nil, nil}
  end

  defp resolve_profile(_uid, _app_id), do: {nil, nil}

  defp presign_avatar(media_id, app_id) when is_binary(media_id) and is_binary(app_id) do
    case SharedInfra.MediaClient.get_download_url(%{
           "media_id" => media_id,
           "app_id" => app_id,
           "purpose" => "user_avatar"
         }) do
      {:ok, download} -> Map.get(download, :download_url) || Map.get(download, "download_url")
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp presign_avatar(_media_id, _app_id), do: nil

  defp session(conn) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}) do
      {:ok, session}
    else
      _ -> {:error, :session_invalid}
    end
  end

  defp session_app(session), do: Map.get(session, :app_id)

  defp authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, "Bearer " <> token}
      _ -> {:error, :session_invalid}
    end
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil

  defp unauthorized(conn),
    do: ErrorResponse.unauthorized(conn, "auth.session_invalid", "Invalid or missing session")
end
