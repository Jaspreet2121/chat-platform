defmodule ApiGatewayWeb.PushController do
  @moduledoc """
  Web-push subscription registration (Phase 1). Session-gated; the caller registers/removes THEIR
  OWN browser's subscription: `POST /api/v1/push/subscriptions {endpoint, keys:{p256dh, auth}}`
  (upsert by endpoint) and `DELETE /api/v1/push/subscriptions {endpoint}`. The private VAPID key
  never leaves the notification service; nothing is sent from here.
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  def create(conn, %{"endpoint" => endpoint, "keys" => %{"p256dh" => p256dh, "auth" => auth}} = params)
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
