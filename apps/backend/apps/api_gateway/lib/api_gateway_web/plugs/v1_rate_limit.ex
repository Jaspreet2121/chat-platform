defmodule ApiGatewayWeb.Plugs.V1RateLimit do
  @moduledoc """
  Per-app rate limit for `/v1` (token bucket keyed by the authenticated app_id). Runs AFTER V1Auth, so
  `:v1_app_id` is assigned. Over the limit → 429 with a non-leaky body + Retry-After. See
  `ApiGatewayWeb.V1Runtime` for the prod-grade (Redis) swap point.
  """

  import Plug.Conn

  alias ApiGatewayWeb.ErrorResponse

  def init(opts), do: opts

  def call(conn, _opts) do
    case ApiGatewayWeb.V1Runtime.check_rate(conn.assigns[:v1_app_id]) do
      :ok ->
        conn

      {:error, :rate_limited, retry_after_seconds} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds))
        |> ErrorResponse.rate_limited("v1.rate_limited")
        |> halt()
    end
  end
end
