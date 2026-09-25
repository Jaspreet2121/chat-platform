defmodule ApiGatewayWeb.Plugs.RateLimit do
  @moduledoc """
  Route-level API rate limiting plug, keyed on (client IP, OTP target) — and, since 128, optionally on
  the CLIENT ADDRESS ALONE as a second, wider bucket charged in the same call.

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

  ## THE ADDRESS-ONLY BUCKET (128), AND THE HOLE IT CLOSES

  The (address, phone) key bounds how hard one caller can push ONE number. It bounds nothing at all
  about how MANY numbers they push: a fresh phone is a fresh key, so a single client could request
  OTPs for unlimited distinct numbers at the per-number rate, forever. Since possession of a phone
  number is the only real friction on creating an account, that made account creation effectively
  free at volume — and account creation is what every abuse story in this product starts with.

  `ip_limit` / `ip_window_seconds` add a second counter keyed on the address alone. BOTH are charged
  on every call, and either can refuse. The narrow key still does its job on one victim's number; the
  wide key caps the farm.

  Sized for a shared address, not for one person: the worst a single legitimate sign-in costs is
  about three requests, so 30/hour is roughly ten people an hour behind one NAT — comfortable for a
  home, an office or a café, and a hard ceiling of 30 numbers an hour for anyone farming accounts,
  down from no ceiling at all. Fail-closed like its sibling, for the same reason.

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
    prefix = Keyword.get(opts, :key_prefix, "auth:otp_request")
    fail_open = Keyword.get(opts, :fail_open, false)

    # THE WIDE BUCKET FIRST, when the route configures one. Order matters only for which refusal a
    # farming client sees, and this is the right one: a caller who has burned the address budget is
    # refused for that reason rather than being told a specific number is busy.
    case check_address_bucket(conn, opts, prefix, fail_open) do
      :pass -> check_target_bucket(conn, opts, prefix, fail_open)
      {:halt, halted} -> halted
    end
  end

  # The address-only counter (128). Absent `ip_limit`, this is a no-op and the route behaves exactly
  # as it did — only /auth/otp/request opts into it.
  defp check_address_bucket(conn, opts, prefix, fail_open) do
    case Keyword.get(opts, :ip_limit) do
      nil ->
        :pass

      ip_limit ->
        decide(
          conn,
          RateLimiter.check_rate(%{
            "key" => "#{prefix}:addr:#{client_ip(conn)}",
            "limit" => ip_limit,
            "window_seconds" => Keyword.fetch!(opts, :ip_window_seconds),
            "fail_open" => fail_open
          }),
          fail_open
        )
    end
  end

  defp check_target_bucket(conn, opts, prefix, fail_open) do
    case decide(
           conn,
           RateLimiter.check_rate(%{
             "key" => rate_key(conn, prefix),
             "limit" => Keyword.fetch!(opts, :limit),
             "window_seconds" => Keyword.fetch!(opts, :window_seconds),
             "fail_open" => fail_open
           }),
           fail_open
         ) do
      :pass -> conn
      {:halt, halted} -> halted
    end
  end

  # `:pass` or `{:halt, conn}` — never a bare conn, so a caller cannot mistake "allowed" for
  # "already answered" when two buckets are charged in sequence.
  defp decide(conn, result, fail_open) do
    case result do
      :ok ->
        :pass

      {:error, :rate_limited, retry_after_seconds} ->
        {:halt,
         conn
         |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds))
         |> ErrorResponse.rate_limited("rate_limit.exceeded")
         |> halt()}

      # Limiter outage (or malformed attrs). Fail-closed → 503 with the same shape contacts/broadcast
      # already use; fail-open → let the request through.
      _other ->
        if fail_open, do: :pass, else: {:halt, limiter_unavailable(conn)}
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

  # ONE definition of "the real client IP", shared with the admin audit writer — see
  # ApiGatewayWeb.RequestContext for why the rightmost x-forwarded-for entry is the only
  # unforgeable one. A second copy here would drift from the one the audit log records.
  defp client_ip(conn), do: ApiGatewayWeb.RequestContext.client_ip(conn)

  defp enabled? do
    Application.get_env(:api_gateway, :rate_limiting_enabled, false) ||
      System.get_env("API_RATE_LIMITING_ENABLED") in ["true", "1", "yes"]
  end
end
