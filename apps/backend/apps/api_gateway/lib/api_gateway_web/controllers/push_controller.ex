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
    with_session(conn, fn session ->
      SharedInfra.AuthClient.save_push_subscription(%{
        "user_id" => session.user_id,
        "endpoint" => endpoint,
        "p256dh" => p256dh,
        "auth" => auth,
        "user_agent" => params["user_agent"] || first_header(conn, "user-agent"),
        # 103: the SESSION's device identity, never client-supplied — device revocation deletes the
        # browser's subscriptions by this linkage.
        "device_id" => session.device_id
      })
    end)
  end

  def create(conn, _params), do: ErrorResponse.invalid_request(conn, "push.invalid_subscription")

  def delete(conn, %{"endpoint" => endpoint}) when is_binary(endpoint) and endpoint != "" do
    with_session(conn, fn session ->
      SharedInfra.AuthClient.delete_push_subscription(%{
        "user_id" => session.user_id,
        "endpoint" => endpoint
      })
    end)
  end

  def delete(conn, _params), do: ErrorResponse.invalid_request(conn, "push.invalid_subscription")

  # ---- Android FCM device tokens (Phase 2) ----

  # THE DEVICE COMES FROM THE SESSION, NEVER THE BODY. The body's device_id used to be stored
  # verbatim, and a client-claimed value is how one handset piled up three device identities (and
  # three token rows) under one account. The session's device_id is the one the client registered
  # at login — the same value a correct client would have put in the body — so nothing changes for
  # it; a body device_id is now simply ignored. No session device (a placeholder session, or a
  # session minted before device ids existed) is a 422: a row that names no device could never be
  # updated or revoked again.
  def create_token(conn, %{"token" => token} = _params) when is_binary(token) and token != "" do
    with_session_no_content(conn, fn session ->
      case session_device_id(session) do
        nil ->
          {:error, :device_required}

        device_id ->
          SharedInfra.AuthClient.save_fcm_token(%{
            "user_id" => session.user_id,
            "token" => token,
            "device_id" => device_id,
            "platform" => "android"
          })
      end
    end)
  end

  def create_token(conn, _params), do: ErrorResponse.invalid_request(conn, "push.invalid_token")

  def delete_token(conn, %{"token" => token}) when is_binary(token) and token != "" do
    with_session_no_content(conn, fn session ->
      SharedInfra.AuthClient.delete_fcm_token(%{"user_id" => session.user_id, "token" => token})
    end)
  end

  def delete_token(conn, _params), do: ErrorResponse.invalid_request(conn, "push.invalid_token")

  defp session_device_id(session) do
    case Map.get(session, :device_id) || Map.get(session, "device_id") do
      device_id when is_binary(device_id) and device_id != "" -> device_id
      _ -> nil
    end
  end

  # Same session gate and the same error mapping as `with_session/2` — only the success shape
  # differs (204, no body: registering a device token has nothing to report back).
  defp with_session_no_content(conn, operation) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, _response} <- operation.(session) do
      send_resp(conn, :no_content, "")
    else
      {:error, :session_invalid} ->
        ErrorResponse.unauthorized(conn, "auth.session_invalid", "Session token is invalid")

      {:error, :auth_unavailable} ->
        ErrorResponse.service_unavailable(conn, "push.unavailable")

      {:error, :device_required} ->
        ErrorResponse.unprocessable_entity(
          conn,
          "push.device_required",
          "This session carries no device id — sign in again to register for push"
        )

      _ ->
        ErrorResponse.invalid_request(conn, "push.invalid_token")
    end
  end

  defp with_session(conn, operation) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, response} <- operation.(session) do
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
