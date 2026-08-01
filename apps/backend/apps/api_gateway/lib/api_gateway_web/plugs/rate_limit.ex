defmodule ApiGatewayWeb.Plugs.RateLimit do
  @moduledoc """
  Route-level API rate limiting plug, keyed on (client IP, OTP target).

  Used by the two PRE-SESSION auth routes — the only endpoints in the system a caller can reach
  without a user id to key on:

    * `POST /auth/otp/request` — 3/60s. Bounds SMS spend and victim bombing.
    * `POST /auth/otp/verify`  — 20/300s. Bounds an attacker who works around the per-otp_request_id
      attempts cap (`AuthService.OTP.max_verify_attempts/0`) by requesting a FRESH id each time.

  THE TWO VERIFY LIMITS COMPOSE, and neither is redundant:

    * the per-id cap (5, in auth_service) stops brute-forcing ONE code, and burns it on exhaustion;
    * this per-(IP, phone) limit stops the BYPASS of that cap — otherwise an attacker simply calls
      /otp/request for a new id and buys another 5 guesses, indefinitely.

  So the ceiling per target is min(5 guesses per code, 20 verifies per 5 min) against a 10^6 space
  with a 300s TTL; /otp/request at 3/60s is what makes fresh ids expensive.

  FAIL-CLOSED (`fail_open: false` by default here). These limiters ARE the security control — the
  anti-fraud gate on SMS spend and the outer bound on OTP brute force — so a limiter outage must
  reject rather than silently reopen the takeover path. Follows the contacts-sync/broadcast
  precedent, and deliberately inverts this plug's original fail-open stance from when it was only an
  availability guard.
  """

  import Plug.Conn

  alias ApiGatewayWeb.ErrorResponse
  alias SharedInfra.RateLimiter

  # A short Retry-After on the fail-closed 503 so a client doesn't hammer a degraded limiter
  # (the contacts_controller number).
  @limiter_outage_retry 30

  def init(opts), do: opts

  def call(conn, opts) do
    if enabled?() do
      check_rate(conn, opts)
    else
      conn
    end
  end

  defp check_rate(conn, opts) do
    limit = Keyword.fetch!(opts, :limit)
    window_seconds = Keyword.fetch!(opts, :window_seconds)
    prefix = Keyword.get(opts, :key_prefix, "auth:otp_request")
    fail_open = Keyword.get(opts, :fail_open, false)

    case RateLimiter.check_rate(%{
           "key" => rate_key(conn, prefix),
           "limit" => limit,
           "window_seconds" => window_seconds,
           "fail_open" => fail_open
         }) do
      :ok ->
        conn

      {:error, :rate_limited, retry_after_seconds} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds))
        |> ErrorResponse.rate_limited("rate_limit.exceeded")
        |> halt()

      # Limiter outage (or malformed attrs). Fail-closed → 503 with the same shape contacts/broadcast
      # already use; fail-open → let the request through.
      _other ->
        if fail_open, do: conn, else: limiter_unavailable(conn)
    end
  end

  defp limiter_unavailable(conn) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(@limiter_outage_retry))
    |> ErrorResponse.service_unavailable("auth.limiter_unavailable")
    |> halt()
  end

  defp rate_key(conn, prefix) do
    target =
      conn.params
      |> Map.get("phone_number", Map.get(conn.params, "email", "unknown"))
      |> normalize_target()

    "#{prefix}:#{client_ip(conn)}:#{target}"
  end

  defp normalize_target(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_target(_value), do: "unknown"

  # THE REAL CLIENT IP, not the proxy's. Every request reaches this app through Caddy, so
  # `conn.remote_ip` is the Caddy container's bridge address — IDENTICAL for every caller. That
  # silently collapsed this key's IP component to a constant and made per-IP limiting decorative.
  # Caddy's reverse_proxy sets X-Forwarded-For by default.
  #
  # We take the LAST entry, not the first. A client can send its own X-Forwarded-For; Caddy APPENDS
  # the address it actually observed, so the rightmost entry is the one value the client cannot
  # forge. Taking the leftmost (what Plug.RewriteOn does) would let an attacker spoof a fresh IP per
  # request and walk straight around this limit. Correct because there is exactly ONE trusted proxy
  # in front of this app and the gateway port is NOT published — revisit if either changes.
  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [] ->
        peer_ip(conn)

      headers ->
        headers
        |> Enum.join(",")
        |> String.split(",")
        |> List.last()
        |> String.trim()
        |> case do
          "" -> peer_ip(conn)
          address -> address
        end
    end
  end

  # :inet.ntoa renders IPv4 and IPv6 correctly. The old Enum.join(".") produced a bogus
  # dotted string for IPv6 8-tuples — stable, so it "worked", but it was not an address.
  defp peer_ip(%{remote_ip: remote_ip}) when is_tuple(remote_ip) do
    case :inet.ntoa(remote_ip) do
      address when is_list(address) -> List.to_string(address)
      _ -> "unknown"
    end
  end

  defp peer_ip(_conn), do: "unknown"

  defp enabled? do
    Application.get_env(:api_gateway, :rate_limiting_enabled, false) ||
      System.get_env("API_RATE_LIMITING_ENABLED") in ["true", "1", "yes"]
  end
end
