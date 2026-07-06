defmodule ApiGatewayWeb.CallController do
  @moduledoc """
  Phase-1 calling — LiveKit access tokens. Mints a room-scoped LiveKit JWT for the authenticated user so
  the client can join the SFU. Slice 1 accepts a room name directly; call-row validation (that the user is
  a participant of that call) arrives in a later slice.
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  # POST /api/v1/calls/token  { "room": "<room_name>" }
  # → { "url": "wss://…", "token": "<livekit jwt>" } for the current user + room.
  def token(conn, %{"room" => room}) when is_binary(room) and room != "" do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, jwt} <- SharedInfra.LiveKitToken.create(session.user_id, room, name: session.user_id) do
      json(conn, %{url: SharedInfra.LiveKitToken.url(), token: jwt})
    else
      {:error, :livekit_not_configured} ->
        ErrorResponse.service_unavailable(conn, "calls.unavailable")

      _ ->
        ErrorResponse.unauthorized(conn, "auth.unauthorized", "Invalid or missing session")
    end
  end

  def token(conn, _params), do: ErrorResponse.invalid_request(conn, "calls.room_required")

  defp authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token = authorization] when token != "" -> {:ok, authorization}
      _ -> {:error, :session_invalid}
    end
  end
end
