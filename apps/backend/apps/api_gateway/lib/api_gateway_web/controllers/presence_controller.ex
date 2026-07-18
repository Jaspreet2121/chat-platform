defmodule ApiGatewayWeb.PresenceController do
  @moduledoc """
  First-party presence read for the web app. `GET /api/v1/presence?user_ids=a,b,c` → the online/last-seen
  snapshot for those users AS THE CALLER may see them (privacy-filtered, fail-closed — same
  `ApiGatewayWeb.PresenceRead` the /v1 surface uses). Session-authenticated.
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse
  alias ApiGatewayWeb.PresenceRead

  def index(conn, params) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}) do
      ids = PresenceRead.parse_ids(params["user_ids"])
      json(conn, %{presence: PresenceRead.snapshot(session.user_id, ids)})
    else
      {:error, :session_invalid} -> ErrorResponse.unauthorized(conn, "auth.session_invalid", "Invalid session")
      {:error, :auth_unavailable} -> ErrorResponse.service_unavailable(conn, "auth.unavailable")
      _ -> ErrorResponse.unauthorized(conn, "auth.session_invalid", "Invalid session")
    end
  end

  defp authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, "Bearer " <> token}
      _ -> {:error, :session_invalid}
    end
  end
end
