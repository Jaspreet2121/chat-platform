defmodule ApiGatewayWeb.SearchController do
  @moduledoc """
  Message search. The result set is scoped server-side to the caller's own conversations (privacy) —
  see `MessageService.Search`. Requires a valid session; `q` must be at least 2 chars.
  """

  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  # GET /api/v1/search/messages?q=&page= — ILIKE over message bodies in the caller's conversations.
  def messages(conn, params) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, response} <-
           SharedInfra.MessageClient.search_messages(%{
             "user_id" => session.user_id,
             "query" => Map.get(params, "q"),
             "page" => Map.get(params, "page")
           }) do
      json(conn, response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :message_unavailable} -> service_unavailable(conn)
      {:error, :query_too_short} -> invalid_request(conn, "search.query_too_short")
      _ -> invalid_request(conn, "search.invalid_request")
    end
  end

  defp authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> _token = authorization] -> {:ok, authorization}
      _ -> {:error, :session_invalid}
    end
  end

  defp invalid_request(conn, code), do: ErrorResponse.invalid_request(conn, code)

  defp service_unavailable(conn),
    do: ErrorResponse.service_unavailable(conn, "search.unavailable")

  defp unauthorized(conn),
    do: ErrorResponse.unauthorized(conn, "search.unauthorized", "Missing or invalid access token")
end
