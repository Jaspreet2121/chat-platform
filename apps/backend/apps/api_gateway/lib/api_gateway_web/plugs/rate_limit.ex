defmodule ApiGatewayWeb.Plugs.RateLimit do
  @moduledoc """
  Route-level API rate limiting plug.
  """

  import Plug.Conn

  alias ApiGatewayWeb.ErrorResponse
  alias SharedInfra.RateLimiter

  def init(opts), do: opts

  def call(conn, opts) do
    if enabled?() do
      check_rate(conn, opts)
    else
      conn
    end
  end

  defp check_rate(conn, opts) do
    key = otp_request_key(conn)
    limit = Keyword.fetch!(opts, :limit)
    window_seconds = Keyword.fetch!(opts, :window_seconds)

    case RateLimiter.check_rate(%{
           "key" => key,
           "limit" => limit,
           "window_seconds" => window_seconds
         }) do
      :ok ->
        conn

      {:error, :rate_limited, retry_after_seconds} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds))
        |> ErrorResponse.rate_limited("rate_limit.exceeded")
        |> halt()

      {:error, :rate_limiter_unavailable, _plan} ->
        conn

      {:error, :rate_limiter_unavailable} ->
        conn

      {:error, _reason} ->
        conn
    end
  end

  defp otp_request_key(conn) do
    target =
      conn.params
      |> Map.get("phone_number", Map.get(conn.params, "email", "unknown"))
      |> normalize_target()

    "auth:otp_request:#{client_ip(conn)}:#{target}"
  end

  defp normalize_target(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_target(_value), do: "unknown"

  defp client_ip(%{remote_ip: remote_ip}) when is_tuple(remote_ip) do
    remote_ip
    |> Tuple.to_list()
    |> Enum.join(".")
  end

  defp client_ip(_conn), do: "unknown"

  defp enabled? do
    Application.get_env(:api_gateway, :rate_limiting_enabled, false) ||
      System.get_env("API_RATE_LIMITING_ENABLED") in ["true", "1", "yes"]
  end
end
