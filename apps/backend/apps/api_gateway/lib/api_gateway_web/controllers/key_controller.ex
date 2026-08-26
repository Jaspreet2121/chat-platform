defmodule ApiGatewayWeb.KeyController do
  @moduledoc """
  Device public-key registry (107) — the offline-messaging foundation.

    POST /api/v1/keys/device      → upload/rotate THIS session's device keys (device_id from the
                                    session, never the body — a client cannot claim another device).
    GET  /api/v1/keys/users?ids=  → the requested users' active devices' public keys, membership-
                                    gated at the store (strangers silently omitted — no oracle).

  Both fail CLOSED on a limiter outage: key distribution is a correctness surface for E2E clients.
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  @upload_limit 10
  @fetch_limit 30
  @window_seconds 60
  @limiter_outage_retry 30

  def upload(conn, params) do
    with {:ok, session} <- session(conn),
         :ok <- rate_limit("keys_upload", session.user_id, @upload_limit),
         {:ok, result} <-
           SharedInfra.AuthClient.save_device_keys(%{
             "user_id" => session.user_id,
             "device_id" => session.device_id,
             "app_id" => session_app(session),
             "ed25519_public" => Map.get(params, "ed25519_public"),
             "x25519_public" => Map.get(params, "x25519_public")
           }) do
      # SECRET CHATS (108): a genuine key change (first upload or rotation — the store says which)
      # notifies every secret conversation this user is in. Best-effort; the upload already stands.
      if Map.get(result, :changed) == true or Map.get(result, "changed") == true do
        ApiGatewayWeb.SecretChatEvents.emit_keys_changed(session.user_id)
      end

      json(conn, result)
    else
      error -> handle_error(conn, error)
    end
  end

  def users(conn, params) do
    with {:ok, session} <- session(conn),
         :ok <- rate_limit("keys_fetch", session.user_id, @fetch_limit),
         {:ok, result} <-
           SharedInfra.AuthClient.fetch_device_keys(%{
             "user_id" => session.user_id,
             "app_id" => session_app(session),
             "ids" => ids_param(params)
           }) do
      json(conn, result)
    else
      error -> handle_error(conn, error)
    end
  end

  defp ids_param(params) do
    case Map.get(params, "ids") do
      value when is_binary(value) -> value |> String.split(",", trim: true)
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp session(conn) do
    with ["Bearer " <> token] when token != "" <- get_req_header(conn, "authorization"),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => "Bearer " <> token}) do
      {:ok, session}
    else
      _ -> {:error, :session_invalid}
    end
  end

  defp rate_limit(kind, user_id, limit) do
    case SharedInfra.RateLimiter.check_rate(%{
           "key" => kind <> ":" <> user_id,
           "limit" => limit,
           "window_seconds" => @window_seconds,
           "fail_open" => false
         }) do
      :ok -> :ok
      {:error, :rate_limited, _retry} = limited -> limited
      _ -> {:error, :rate_limiter_unavailable}
    end
  end

  defp handle_error(conn, {:error, :session_invalid}),
    do: ErrorResponse.unauthorized(conn, "auth.session_invalid", "Invalid or expired session")

  defp handle_error(conn, {:error, :rate_limited, retry}) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry))
    |> ErrorResponse.rate_limited("keys.rate_limited")
  end

  defp handle_error(conn, {:error, :rate_limiter_unavailable}) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(@limiter_outage_retry))
    |> ErrorResponse.service_unavailable("keys.unavailable")
  end

  defp handle_error(conn, {:error, :auth_unavailable}),
    do: ErrorResponse.service_unavailable(conn, "keys.unavailable")

  defp handle_error(conn, {:error, :device_keys_invalid}),
    do:
      ErrorResponse.invalid_request_with(
        conn,
        "keys.invalid",
        "Keys must be base64-encoded 32-byte values",
        %{}
      )

  defp handle_error(conn, _), do: ErrorResponse.invalid_request(conn, "keys.invalid")

  defp session_app(session), do: Map.get(session, :app_id) || Map.get(session, "app_id")
end
