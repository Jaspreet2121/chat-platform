defmodule ApiGatewayWeb.Plugs.RequireAdmin do
  @moduledoc """
  Gates `/api/v1/admin/*` routes on the global platform-admin flag.

  Resolves the bearer session via the same `SharedInfra.AuthClient.current_session/1` path every
  controller uses, then requires `is_admin`. On success the resolved session is stashed in
  `conn.assigns.admin_session` so the admin controller doesn't re-resolve it. On failure it halts with
  the standard JSON error envelope: 401 when the session is missing/invalid, 403 when the user is
  authenticated but not an admin, 503 when auth is unreachable.

  Referencing `session.is_admin` here also ensures the `:is_admin` atom exists in this app's BEAM, so
  the HTTP auth-client decode (`String.to_existing_atom`) rehydrates the key as an atom over the wire.
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

  defp session_admin?(session), do: Map.get(session, :is_admin) == true

  defp authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> _token = authorization] -> {:ok, authorization}
      _ -> {:error, :session_invalid}
    end
  end
end
