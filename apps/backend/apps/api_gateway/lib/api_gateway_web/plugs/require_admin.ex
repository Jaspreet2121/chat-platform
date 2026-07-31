defmodule ApiGatewayWeb.Plugs.RequireAdmin do
  @moduledoc """
  Scope-level gate for `/api/v1/admin/*`: requires ANY admin console role (IAM migration 058:
  root/admin/moderator/support). Per-route capability is then enforced by
  `ApiGatewayWeb.Plugs.RequirePermission` in each controller.

  Resolves the bearer session via the same `SharedInfra.AuthClient.current_session/1` path every
  controller uses, then requires `SharedInfra.IAM.console_access?(session.role)` (with a legacy
  `is_admin == true` fallback so nothing regresses if `role` is ever absent). On success the resolved
  session is stashed in `conn.assigns.admin_session`. On failure it halts with the standard JSON error
  envelope: 401 (missing/invalid session), 403 (authenticated, no console access), 503 (auth down).

  Referencing `session.role`/`:is_admin` here also ensures those atoms exist in this app's BEAM, so the
  HTTP auth-client decode (`String.to_existing_atom`) rehydrates the keys as atoms over the wire.
  """

  import Plug.Conn

  alias ApiGatewayWeb.ErrorResponse

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         true <- session_admin?(session) do
      assign(conn, :admin_session, session)
    else
      {:error, :auth_unavailable} ->
        conn |> ErrorResponse.service_unavailable("admin.unavailable") |> halt()

      false ->
        conn
        |> ErrorResponse.forbidden("admin.forbidden", "Admin access required")
        |> halt()

      _ ->
        conn
        |> ErrorResponse.unauthorized("admin.unauthorized", "Missing or invalid access token")
        |> halt()
    end
  end

  # Console access = any admin role (root/admin/moderator/support). Legacy is_admin==true is a safety
  # fallback so the existing admin never loses access even if `role` failed to propagate.
  defp session_admin?(session) do
    SharedInfra.IAM.console_access?(Map.get(session, :role)) or
      Map.get(session, :is_admin) == true
  end

  defp authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> _token = authorization] -> {:ok, authorization}
      _ -> {:error, :session_invalid}
    end
  end
end
