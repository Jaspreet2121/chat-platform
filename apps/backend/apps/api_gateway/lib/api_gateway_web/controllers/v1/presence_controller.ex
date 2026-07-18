defmodule ApiGatewayWeb.V1.PresenceController do
  @moduledoc """
  Public `/v1` presence read for integrator SDKs. `GET /v1/presence?user_ids=a,b,c` → the online/last-seen
  snapshot for those users AS THE CALLER may see them (privacy-filtered, fail-closed; see
  `ApiGatewayWeb.PresenceRead`). END-USER token only — presence is a per-user relation, and an app-actor has
  no user to authorize against.

  This is the snapshot a client loads before it subscribes for live updates over the socket.
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse
  alias ApiGatewayWeb.PresenceRead

  def index(conn, params) do
    case conn.assigns[:v1_user_id] do
      caller when is_binary(caller) and caller != "" ->
        ids = PresenceRead.parse_ids(params["user_ids"])
        json(conn, %{presence: PresenceRead.snapshot(caller, ids)})

      _ ->
        ErrorResponse.forbidden(conn, "v1.end_user_only", "This endpoint requires an end-user token")
    end
  end
end
