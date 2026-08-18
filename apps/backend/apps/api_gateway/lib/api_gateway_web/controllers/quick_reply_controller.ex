defmodule ApiGatewayWeb.QuickReplyController do
  @moduledoc """
  Custom slash commands (quick replies, 100) — session-authed owner CRUD + ordering over
  `UserService.QuickReplies`. Gateway-owned rules: RESERVED names (the built-in command list) are
  refused with 409; an attached media must BELONG to the caller (the avatar-validation posture);
  writes are rate-limited 30/min/user (fail-open — user data, not a security oracle); every
  successful mutation broadcasts `quick_replies_changed` on the caller's user topic so other
  devices refresh their palette.
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.BuiltinCommands
  alias ApiGatewayWeb.ErrorResponse

  @write_limit 30
  @write_window_seconds 60

  def index(conn, _params) do
    with {:ok, session} <- session(conn),
         {:ok, result} <-
           SharedInfra.UserClient.list_quick_replies(%{"user_id" => session.user_id}) do
      json(conn, %{quick_replies: mget(result, :quick_replies) || []})
    else
      error -> handle_error(conn, error)
    end
  end

  def create(conn, params) do
    with {:ok, session} <- session(conn),
         :ok <- write_rate_limit(session.user_id),
         :ok <- refuse_reserved(Map.get(params, "shortcut")),
         :ok <- validate_media_ownership(params, session),
         {:ok, result} <-
           SharedInfra.UserClient.create_quick_reply(%{
             "user_id" => session.user_id,
             "app_id" => Map.get(session, :app_id),
             "shortcut" => Map.get(params, "shortcut"),
             "body" => Map.get(params, "body"),
             "media_id" => Map.get(params, "media_id")
           }) do
      broadcast_changed(session.user_id)
      conn |> put_status(:created) |> json(result)
    else
      error -> handle_error(conn, error)
    end
  end

  def update(conn, %{"id" => id} = params) when is_binary(id) and id != "" do
    with {:ok, session} <- session(conn),
         :ok <- write_rate_limit(session.user_id),
         :ok <- refuse_reserved(Map.get(params, "shortcut")),
         :ok <- validate_media_ownership(params, session),
         {:ok, result} <-
           SharedInfra.UserClient.update_quick_reply(
             params
             |> Map.take(["id", "shortcut", "body", "media_id"])
             |> Map.put("user_id", session.user_id)
           ) do
      broadcast_changed(session.user_id)
      json(conn, result)
    else
      error -> handle_error(conn, error)
    end
  end

  def update(conn, _params),
    do: ErrorResponse.invalid_request(conn, "quick_reply.invalid_request")

  def delete(conn, %{"id" => id}) when is_binary(id) and id != "" do
    with {:ok, session} <- session(conn),
         :ok <- write_rate_limit(session.user_id),
         {:ok, result} <-
           SharedInfra.UserClient.delete_quick_reply(%{"user_id" => session.user_id, "id" => id}) do
      broadcast_changed(session.user_id)
      json(conn, result)
    else
      error -> handle_error(conn, error)
    end
  end

  def delete(conn, _params),
    do: ErrorResponse.invalid_request(conn, "quick_reply.invalid_request")

  def reorder(conn, params) do
    with {:ok, session} <- session(conn),
         :ok <- write_rate_limit(session.user_id),
         ids when is_list(ids) <- Map.get(params, "ids"),
         {:ok, result} <-
           SharedInfra.UserClient.reorder_quick_replies(%{
             "user_id" => session.user_id,
             "ids" => ids
           }) do
      broadcast_changed(session.user_id)
      json(conn, %{quick_replies: mget(result, :quick_replies) || []})
    else
      nil -> ErrorResponse.invalid_request(conn, "quick_reply.invalid_request")
      error -> handle_error(conn, error)
    end
  end

  # --- rules -------------------------------------------------------------------------------------

  defp refuse_reserved(nil), do: :ok

  defp refuse_reserved(shortcut) when is_binary(shortcut) do
    if BuiltinCommands.reserved?(shortcut), do: {:error, :reserved}, else: :ok
  end

  defp refuse_reserved(_), do: :ok

  # An attached media must be the CALLER's own asset (same posture as avatar_media_id validation) —
  # otherwise a quick reply becomes a read oracle for other people's media ids.
  defp validate_media_ownership(params, session) do
    case Map.get(params, "media_id") do
      empty when empty in [nil, ""] ->
        :ok

      media_id ->
        case SharedInfra.MediaClient.get_asset(%{
               "media_id" => media_id,
               "app_id" => Map.get(session, :app_id)
             }) do
          {:ok, asset} ->
            if mget(asset, :owner_user_id) == session.user_id,
              do: :ok,
              else: {:error, :media_not_owned}

          _ ->
            {:error, :media_not_owned}
        end
    end
  end

  defp write_rate_limit(user_id) do
    case SharedInfra.RateLimiter.check_rate(%{
           "key" => "quick_reply_write:" <> user_id,
           "limit" => @write_limit,
           "window_seconds" => @write_window_seconds
         }) do
      :ok -> :ok
      {:error, :rate_limited, _retry} = limited -> limited
      # Fail OPEN: user data, not a security control (registered in RATE_LIMIT_POLICY.md).
      _ -> :ok
    end
  end

  defp broadcast_changed(user_id) do
    ApiGatewayWeb.Endpoint.broadcast("user:" <> user_id, "quick_replies_changed", %{})
  end

  defp handle_error(conn, error) do
    case error do
      {:error, :session_invalid} ->
        ErrorResponse.unauthorized(conn, "auth.session_invalid", "Session token is invalid")

      {:error, :auth_unavailable} ->
        ErrorResponse.service_unavailable(conn, "quick_reply.unavailable")

      {:error, :user_unavailable} ->
        ErrorResponse.service_unavailable(conn, "quick_reply.unavailable")

      {:error, :quick_reply_unavailable} ->
        ErrorResponse.service_unavailable(conn, "quick_reply.unavailable")

      {:error, :reserved} ->
        ErrorResponse.conflict(
          conn,
          "quick_reply.reserved",
          "That shortcut is a built-in command"
        )

      {:error, :quick_reply_taken} ->
        ErrorResponse.conflict(conn, "quick_reply.taken", "You already use that shortcut")

      {:error, :quick_reply_limit} ->
        ErrorResponse.conflict(conn, "quick_reply.limit", "Quick reply limit reached (50)")

      {:error, :quick_reply_not_found} ->
        ErrorResponse.not_found(conn, "quick_reply.not_found", "Quick reply not found")

      {:error, :media_not_owned} ->
        ErrorResponse.unprocessable_entity(conn, "quick_reply.invalid_media", "Invalid media")

      {:error, :rate_limited, retry_after_seconds} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds))
        |> ErrorResponse.rate_limited("quick_reply.rate_limited")

      _ ->
        ErrorResponse.invalid_request(conn, "quick_reply.invalid_request")
    end
  end

  defp session(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token = authorization] when token != "" ->
        SharedInfra.AuthClient.current_session(%{"authorization" => authorization})

      _ ->
        {:error, :session_invalid}
    end
  end

  defp mget(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end
