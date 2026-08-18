defmodule ApiGatewayWeb.CommandController do
  @moduledoc """
  GET /api/v1/commands (100) — the static built-in slash-command list, session-authed and CACHEABLE:
  a strong ETag over the payload; If-None-Match → 304 with no body. The list changes only with a
  deploy, so clients fetch it once per release.
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.BuiltinCommands
  alias ApiGatewayWeb.ErrorResponse

  def index(conn, _params) do
    with {:ok, _session} <- session(conn) do
      body = Jason.encode!(%{commands: BuiltinCommands.all()})
      etag = ~s("#{Base.encode16(:crypto.hash(:sha256, body), case: :lower)}")

      if etag in get_req_header(conn, "if-none-match") do
        conn
        |> put_resp_header("etag", etag)
        |> send_resp(304, "")
      else
        conn
        |> put_resp_header("etag", etag)
        |> put_resp_header("cache-control", "private, max-age=3600")
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)
      end
    else
      _ -> ErrorResponse.unauthorized(conn, "auth.session_invalid", "Session token is invalid")
    end
  end

  defp session(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token = authorization] when token != "" ->
        SharedInfra.AuthClient.current_session(%{"authorization" => authorization})

      _ ->
        {:error, :session_invalid}
    end
  end
end
