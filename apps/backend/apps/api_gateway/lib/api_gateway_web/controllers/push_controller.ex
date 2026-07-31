defmodule ApiGatewayWeb.PushController do
  @moduledoc """
  Push registration (session-gated; the caller registers/removes THEIR OWN device only).

  WEB (Phase 1): `POST /api/v1/push/subscriptions {endpoint, keys:{p256dh, auth}}` (upsert by
  endpoint) and `DELETE /api/v1/push/subscriptions {endpoint}`.

  ANDROID (Phase 2): `POST /api/v1/push/fcm-tokens {token, device_id?}` (upsert by token) and
  `DELETE /api/v1/push/fcm-tokens {token}` — the latter is what the client calls on logout, so a
  handset that signed out stops receiving that account's pushes. Both answer 204 (there is nothing
  for the client to read back), unlike the older subscription routes which echo a body.

  Neither credential leaves the notification service, and nothing is sent from here.
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  def create(
        conn,
        %{"endpoint" => endpoint, "keys" => %{"p256dh" => p256dh, "auth" => auth}} = params
      )
      when is_binary(endpoint) and endpoint != "" do
    with_session(conn, fn user_id ->
      SharedInfra.AuthClient.save_push_subscription(%{
        "user_id" => user_id,
        "endpoint" => endpoint,
        "p256dh" => p256dh,
        "auth" => auth,
        "user_agent" => params["user_agent"] || first_header(conn, "user-agent")
      })
    end)
  end

  def create(conn, _params), do: ErrorResponse.invalid_request(conn, "push.invalid_subscription")

  def delete(conn, %{"endpoint" => endpoint}) when is_binary(endpoint) and endpoint != "" do
    with_session(conn, fn user_id ->
      SharedInfra.AuthClient.delete_push_subscription(%{
        "user_id" => user_id,
        "endpoint" => endpoint
      })
    end)
  end

  def delete(conn, _params), do: ErrorResponse.invalid_request(conn, "push.invalid_subscription")

  # ---- Android FCM device tokens (Phase 2) ----

  def create_token(conn, %{"token" => token} = params) when is_binary(token) and token != "" do
    with_session_no_content(conn, fn user_id ->
      SharedInfra.AuthClient.save_fcm_token(%{
        "user_id" => user_id,
        "token" => token,
        "device_id" => params["device_id"],
        "platform" => "android"
      })
    end)
  end

  def create_token(conn, _params), do: ErrorResponse.invalid_request(conn, "push.invalid_token")

  def delete_token(conn, %{"token" => token}) when is_binary(token) and token != "" do
    with_session_no_content(conn, fn user_id ->
      SharedInfra.AuthClient.delete_fcm_token(%{"user_id" => user_id, "token" => token})
    end)
  end

  def delete_token(conn, _params), do: ErrorResponse.invalid_request(conn, "push.invalid_token")

  # Same session gate and the same error mapping as `with_session/2` — only the success shape
  # differs (204, no body: registering a device token has nothing to report back).
  defp with_session_no_content(conn, operation) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, _response} <- operation.(session.user_id) do
      send_resp(conn, :no_content, "")
    else
      {:error, :session_invalid} ->
        ErrorResponse.unauthorized(conn, "auth.session_invalid", "Session token is invalid")

      {:error, :auth_unavailable} ->
        ErrorResponse.service_unavailable(conn, "push.unavailable")

      _ ->
        ErrorResponse.invalid_request(conn, "push.invalid_token")
    end
  end

  defp with_session(conn, operation) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, response} <- operation.(session.user_id) do
      json(conn, response)
    else
      {:error, :session_invalid} ->
        ErrorResponse.unauthorized(conn, "auth.session_invalid", "Session token is invalid")

      {:error, :auth_unavailable} ->
        ErrorResponse.service_unavailable(conn, "push.unavailable")

      _ ->
        ErrorResponse.invalid_request(conn, "push.invalid_request")
    end
  end

  defp authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, "Bearer " <> token}
      _ -> {:error, :session_invalid}
    end
  end

  defp first_header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> value
      _ -> nil
    end
  end
end
