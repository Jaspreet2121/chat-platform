defmodule ApiGatewayWeb.ErrorResponse do
  @moduledoc """
  Shared JSON error response helpers for API Gateway skeleton controllers.

  Every error envelope carries the request's real `correlation_id` (set by
  `ApiGatewayWeb.Plugs.CorrelationId`), so a client/operator can trace the failure end-to-end.
  The envelope SHAPE is unchanged — only the id is now real instead of a literal placeholder.
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
        correlation_id: correlation_id(conn)
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
        correlation_id: correlation_id(conn)
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
        correlation_id: correlation_id(conn)
      }
    })
  end

  # 413 for an upload whose declared size exceeds the server cap (MEDIA_MAX_SIZE_BYTES).
  def payload_too_large(conn, code, message) do
    conn
    |> put_status(:request_entity_too_large)
    |> json(%{
      error: %{
        code: code,
        message: message,
        correlation_id: correlation_id(conn)
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
        correlation_id: correlation_id(conn)
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
        correlation_id: correlation_id(conn)
      }
    })
  end

  # The real correlation id: the plug-assigned value, falling back to Logger metadata, and finally
  # a freshly generated id so the field is never blank even on an unexpected path.
  defp correlation_id(conn) do
    conn.assigns[:correlation_id] || SharedInfra.Correlation.get_or_generate()
  end
end
