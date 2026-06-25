defmodule ApiGatewayWeb.StarredController do
  @moduledoc """
  The caller's starred (bookmarked) messages across all conversations. Private to the user — no
  per-conversation membership check here (the store scopes rows by user_id); just a valid session.
  """

  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  # GET /api/v1/starred?page= — newest-starred first, paginated.
  def index(conn, params) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, response} <-
           SharedInfra.MessageClient.list_starred(%{
             "user_id" => session.user_id,
             "page" => Map.get(params, "page")
           }) do
      json(conn, response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :message_unavailable} -> service_unavailable(conn)
      _ -> invalid_request(conn)
    end
  end

  defp authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> _token = authorization] -> {:ok, authorization}
      _ -> {:error, :session_invalid}
    end
  end

  defp invalid_request(conn), do: ErrorResponse.invalid_request(conn, "starred.invalid_request")

  defp service_unavailable(conn),
    do: ErrorResponse.service_unavailable(conn, "starred.unavailable")

  defp unauthorized(conn),
    do:
      ErrorResponse.unauthorized(conn, "starred.unauthorized", "Missing or invalid access token")
end
