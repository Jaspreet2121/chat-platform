defmodule ApiGatewayWeb.ClientConfigController do
  @moduledoc """
  GET /api/v1/client-config (109) — tiny per-app client context, session-authed. Today just
  `e2ee_default` (whether capable clients should opportunistically upgrade 1:1s to E2EE). A
  standalone read on app open, deliberately NOT folded into the conversation list (that hot path
  should not gain a join for an app-level value that never varies per conversation).
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  def show(conn, _params) do
    with {:ok, session} <- session(conn),
         {:ok, config} <-
           SharedInfra.AuthClient.client_config(%{"app_id" => session_app(session)}) do
      json(conn, %{e2ee_default: config_bool(config, :e2ee_default)})
    else
      {:error, :session_invalid} ->
        ErrorResponse.unauthorized(conn, "auth.session_invalid", "Invalid or expired session")

      _ ->
        ErrorResponse.service_unavailable(conn, "client_config.unavailable")
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

  defp config_bool(config, key) do
    case {Map.get(config, key), Map.get(config, Atom.to_string(key))} do
      {value, _} when is_boolean(value) -> value
      {_, value} when is_boolean(value) -> value
      _ -> false
    end
  end

  defp session_app(session), do: Map.get(session, :app_id) || Map.get(session, "app_id")
end
