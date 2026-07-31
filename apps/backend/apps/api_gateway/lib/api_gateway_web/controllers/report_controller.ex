defmodule ApiGatewayWeb.ReportController do
  @moduledoc """
  First-party user reporting — POST /api/v1/reports. Session-authenticated; the reporter is ALWAYS the session
  user (never trusted from the body). Rows land in the EXISTING `user_reports` table via
  `AuthService.Moderation.create_report`, so the admin moderation console picks them up with ZERO admin-side
  change (it scopes by the reported user's app_id, which the row satisfies).

      POST /api/v1/reports
        {reported_user_id, conversation_id?, reported_message_id?, reason, details?} → 201 {report_id}

  `reason` is validated against a fixed set (spam | harassment | impersonation | other); `details` is capped.
  Per-REPORTER rate-limited via SharedInfra.RateLimiter (the same limiter the OTP request path uses) so the
  table can't be flooded. "Report and block" is two client calls (this + POST /blocks), not a combined
  endpoint.
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  @reasons ~w(spam harassment impersonation other)
  @max_details 2000
  @rate_limit 5
  @rate_window_seconds 3600

  def create(conn, %{"reported_user_id" => reported} = params)
      when is_binary(reported) and reported != "" do
    with {:ok, session} <- session(conn),
         {:ok, reason} <- validate_reason(params),
         {:ok, details} <- validate_details(params),
         :ok <- rate_limit(session.user_id),
         {:ok, result} <-
           SharedInfra.AuthClient.create_report(%{
             "reporter_user_id" => session.user_id,
             "reported_user_id" => reported,
             "conversation_id" => params["conversation_id"],
             "reported_message_id" => params["reported_message_id"],
             "reason" => reason,
             "details" => details
           }) do
      report_id = Map.get(result, :report_id) || Map.get(result, "report_id")
      conn |> put_status(:created) |> json(%{report_id: report_id})
    else
      {:error, :session_invalid} ->
        unauthorized(conn)

      {:error, :invalid_reason} ->
        ErrorResponse.invalid_request(conn, "reports.invalid_reason")

      {:error, :details_too_long} ->
        ErrorResponse.invalid_request(conn, "reports.details_too_long")

      {:error, :rate_limited, retry_after_seconds} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds))
        |> ErrorResponse.rate_limited("reports.rate_limited")

      {:error, :report_invalid} ->
        ErrorResponse.invalid_request(conn, "reports.invalid_request")

      {:error, :auth_unavailable} ->
        ErrorResponse.service_unavailable(conn, "reports.unavailable")

      _ ->
        ErrorResponse.invalid_request(conn, "reports.invalid_request")
    end
  end

  def create(conn, _params),
    do: ErrorResponse.invalid_request(conn, "reports.reported_user_required")

  defp validate_reason(%{"reason" => reason}) when reason in @reasons, do: {:ok, reason}
  defp validate_reason(_params), do: {:error, :invalid_reason}

  # details is optional; when present it must be a string within the cap.
  defp validate_details(%{"details" => details}) when is_binary(details) do
    if String.length(details) <= @max_details,
      do: {:ok, details},
      else: {:error, :details_too_long}
  end

  defp validate_details(%{"details" => nil}), do: {:ok, nil}
  defp validate_details(%{"details" => _}), do: {:error, :details_too_long}
  defp validate_details(_params), do: {:ok, nil}

  # Per-reporter throttle. A limiter OUTAGE fails OPEN (a legit report must not be lost because Redis blipped),
  # exactly like the OTP-request plug.
  defp rate_limit(user_id) do
    case SharedInfra.RateLimiter.check_rate(%{
           "key" => "report:" <> user_id,
           "limit" => @rate_limit,
           "window_seconds" => @rate_window_seconds
         }) do
      :ok -> :ok
      {:error, :rate_limited, _retry} = limited -> limited
      _ -> :ok
    end
  end

  defp session(conn) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}) do
      {:ok, session}
    else
      _ -> {:error, :session_invalid}
    end
  end

  defp authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, "Bearer " <> token}
      _ -> {:error, :session_invalid}
    end
  end

  defp unauthorized(conn),
    do: ErrorResponse.unauthorized(conn, "auth.session_invalid", "Invalid or missing session")
end
