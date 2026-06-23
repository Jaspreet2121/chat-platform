defmodule ApiGatewayWeb.ErrorResponse do
  @moduledoc """
  Shared JSON error response helpers for API Gateway skeleton controllers.
  """

  import Plug.Conn
  import Phoenix.Controller

  def invalid_request(conn, code) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error: %{
        code: code,
        message: "Request body is invalid",
        correlation_id: "corr_placeholder"
      }
    })
  end

  def unauthorized(conn, code, message) do
    conn
    |> put_status(:unauthorized)
    |> json(%{
      error: %{
        code: code,
        message: message,
        correlation_id: "corr_placeholder"
      }
    })
  end

  def forbidden(conn, code, message) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      error: %{
        code: code,
        message: message,
        correlation_id: "corr_placeholder"
      }
    })
  end

  def rate_limited(conn, code) do
    conn
    |> put_status(:too_many_requests)
    |> json(%{
      error: %{
        code: code,
        message: "Too many requests. Please try again later.",
        correlation_id: "corr_placeholder"
      }
    })
  end

  # 503 for when a backing service is unreachable over the network (the HTTP client adapters
  # return `{:error, :*_unavailable}` on transport failure). Same envelope shape as the others.
  def service_unavailable(conn, code) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{
      error: %{
        code: code,
        message: "Service temporarily unavailable. Please try again.",
        correlation_id: "corr_placeholder"
      }
    })
  end
end
