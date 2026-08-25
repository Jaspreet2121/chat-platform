defmodule ApiGatewayWeb.AutoReplyController do
  @moduledoc """
  Auto-reply settings (102) — GET/PATCH /api/v1/auto-replies, session-owned. Both blocks default
  DISABLED (an absent row IS the off state); validation is strict at write so the async engine can
  trust what it reads. Every PATCH broadcasts `auto_replies_changed` on the caller's user topic so
  other devices refresh. Writes 30/min/user, fail-open (user data, not a security control).
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  @write_limit 30
  @write_window_seconds 60

  def show(conn, _params) do
    with {:ok, session} <- session(conn),
         {:ok, settings} <-
           SharedInfra.UserClient.get_auto_replies(%{"user_id" => session.user_id}) do
      json(conn, settings)
    else
      error -> handle_error(conn, error)
    end
  end

  def update(conn, params) do
    with {:ok, session} <- session(conn),
         :ok <- write_rate_limit(session.user_id),
         {:ok, settings} <-
           SharedInfra.UserClient.update_auto_replies(%{
             "user_id" => session.user_id,
             "app_id" => Map.get(session, :app_id),
             "away" => Map.get(params, "away"),
             "greeting" => Map.get(params, "greeting")
           }) do
      ApiGatewayWeb.Endpoint.broadcast("user:" <> session.user_id, "auto_replies_changed", %{})
      json(conn, settings)
    else
      error -> handle_error(conn, error)
    end
  end

  defp write_rate_limit(user_id) do
    case SharedInfra.RateLimiter.check_rate(%{
           "key" => "auto_reply_write:" <> user_id,
           "limit" => @write_limit,
           "window_seconds" => @write_window_seconds
         }) do
      :ok -> :ok
      {:error, :rate_limited, _retry} = limited -> limited
      _ -> :ok
    end
  end

  defp handle_error(conn, error) do
    case error do
      {:error, :session_invalid} ->
        ErrorResponse.unauthorized(conn, "auth.session_invalid", "Session token is invalid")

      {:error, :auth_unavailable} ->
        ErrorResponse.service_unavailable(conn, "auto_reply.unavailable")

      {:error, :user_unavailable} ->
        ErrorResponse.service_unavailable(conn, "auto_reply.unavailable")

      {:error, :auto_reply_unavailable} ->
        ErrorResponse.service_unavailable(conn, "auto_reply.unavailable")

      {:error, :auto_reply_unsupported_mode} ->
        ErrorResponse.invalid_request_with(
          conn,
          "auto_reply.unsupported_mode",
          "outside_business_hours needs structured business hours — a recorded follow-up",
          %{}
        )

      {:error, :auto_reply_body_required} ->
        ErrorResponse.invalid_request(conn, "auto_reply.body_required")

      {:error, :auto_reply_invalid_schedule} ->
        ErrorResponse.invalid_request(conn, "auto_reply.invalid_schedule")

      {:error, :auto_reply_too_many_exceptions} ->
        ErrorResponse.invalid_request(conn, "auto_reply.too_many_exceptions")

      {:error, :rate_limited, retry_after_seconds} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds))
        |> ErrorResponse.rate_limited("auto_reply.rate_limited")

      _ ->
        ErrorResponse.invalid_request(conn, "auto_reply.invalid_request")
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
end
