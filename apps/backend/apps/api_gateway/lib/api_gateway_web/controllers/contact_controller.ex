defmodule ApiGatewayWeb.ContactController do
  @moduledoc """
  Contacts sync — `POST /api/v1/contacts/sync`. "Which of my address-book numbers are on the platform?"
  The most privacy-sensitive endpoint in the API, and it's designed as such:

    * PLAINTEXT E.164 over TLS. Hashing E.164 is theatre — the number space is small + structured, so a
      hash is brute-forceable and buys no confidentiality while breaking the indexed match. The client
      normalises to E.164; the server trims + shape-validates and SKIPS any non-E.164 entry (a real
      address book always carries short codes / junk — one bad row must not fail the whole sync).
    * STATELESS. Numbers are matched and discarded. NOTHING about the address book is persisted — no
      stored social graph, no standing liability.
    * ONE app-scoped query against users_auth regardless of batch size (the enumeration oracle's cost is
      bounded), then every match is enriched through the SAME `ProfilePresenter` path the single by-phone
      lookup uses — so block + profile_photo_visibility redaction cannot be bypassed by going bulk.
    * Rate-limited per user as a SECURITY control (not politeness), and FAIL-CLOSED: a limiter outage
      rejects (503) rather than opening the oracle. Budget: batch ≤ #{2000} × ≤ #{10}/hour ⇒ ≤ 20k
      numbers probed per hour per account (~5+ years to sweep one country's mobile space).
    * Self is excluded from results. Non-matches are simply ABSENT — never a "not found" row (that would
      double the payload and tell the client nothing it doesn't already know).

  DEFERRED — a "who can find me by phone" discoverability opt-out. It's meaningless unless it ALSO gates
  the single by-phone lookup (else an attacker just probes one number at a time), and it carries a product
  decision (default + granularity), so it's its own slice. Four steps to pick it up cold:
    1. migration: `user_privacy_settings.discoverable_by_phone boolean NOT NULL DEFAULT true` (both dirs);
    2. expose it via `UserService.Privacy.get_privacy` + the settings-update path;
    3. enforce in BOTH `by_phone` (single) and here (bulk) — a non-discoverable target is simply absent,
       identical to a non-match (no existence reveal);
    4. tests for both paths + the default.
  The seam is marked below (drop non-discoverable user_ids from the match set — one `Enum.reject`).
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.{ErrorResponse, ProfilePresenter}

  # A real address book is 500–2000 entries; 2000 covers it in one shot. Over → 400 (client pages).
  @max_batch 2000
  # As a security control: generous for a real user (initial sync + occasional refresh), tight for
  # enumeration. 10/hour × 2000 = 20k numbers/hour/account.
  @rate_limit 10
  @rate_window_seconds 3600
  # A short Retry-After on the fail-closed 503 so a client doesn't hammer a degraded limiter.
  @limiter_outage_retry 30
  # E.164: "+" then a leading nonzero digit and 7–14 more (8–15 digits total). Anything else is skipped.
  @e164 ~r/^\+[1-9]\d{7,14}$/

  def sync(conn, %{"phone_numbers" => phone_numbers}) when is_list(phone_numbers) do
    with {:ok, session} <- session(conn),
         :ok <- check_batch_size(phone_numbers),
         :ok <- rate_limit(session.user_id) do
      matches =
        phone_numbers
        |> normalize()
        |> match_and_enrich(session)

      json(conn, %{matches: matches})
    else
      {:error, :session_invalid} -> unauthorized(conn)
      {:error, :batch_too_large} -> batch_too_large(conn)
      {:error, :rate_limited, retry_after_seconds} -> rate_limited(conn, retry_after_seconds)
      {:error, :rate_limiter_unavailable} -> limiter_unavailable(conn)
    end
  end

  def sync(conn, _params), do: ErrorResponse.invalid_request(conn, "contacts.phone_numbers_required")

  # --- matching + enrichment ---

  # Empty valid set (all entries malformed) → no query at all; just an empty result.
  defp match_and_enrich([], _session), do: []

  defp match_and_enrich(phones, session) do
    case SharedInfra.AuthClient.lookup_users_by_phones(%{
           "phone_numbers" => phones,
           "app_id" => session_app(session)
         }) do
      {:ok, rows} when is_list(rows) ->
        rows
        # Exclude self — the caller's own number is always in their address book, but you can't "discover"
        # yourself. (Single lookup 409s here; bulk just drops it silently.)
        |> Enum.reject(&(match_user_id(&1) == session.user_id))
        # DISCOVERABILITY SEAM (deferred): |> Enum.reject(&(not discoverable?(match_user_id(&1))))
        |> Enum.flat_map(&enrich(&1, session))

      _ ->
        # Auth unreachable / unexpected shape → no matches rather than a 5xx: the client keeps its address
        # book and can retry. (A partial-truth here can't leak anyone; it just under-reports.)
        []
    end
  end

  # Enrich a single match through the SAME path single by-phone uses: fetch the public profile app-scoped,
  # then apply `ProfilePresenter.present` (block + profile_photo_visibility redaction). A cross-tenant /
  # invalid / no-profile match resolves to `[]` here — absent from the response, exactly as single lookup
  # 404s it. Returns a 0-or-1 element list so `flat_map` drops the misses.
  defp enrich(row, session) do
    user_id = match_user_id(row)
    phone = match_phone(row)

    case SharedInfra.UserClient.get_public_profile(%{
           "user_id" => user_id,
           "app_id" => session_app(session)
         }) do
      {:ok, profile} ->
        presented = ProfilePresenter.present(session.user_id, user_id, profile)

        [
          %{
            # Echo the INPUT number (== the stored match) so the client can join back to its contact.
            phone: phone,
            user_id: user_id,
            display_name: Map.get(presented, :display_name),
            avatar_url: Map.get(presented, :avatar_url)
          }
        ]

      _ ->
        []
    end
  end

  # Rows come atom-keyed in-process and may be string-keyed over the HTTP adapter — accept both.
  defp match_user_id(row), do: Map.get(row, :user_id) || Map.get(row, "user_id")
  defp match_phone(row), do: Map.get(row, :phone_number) || Map.get(row, "phone_number")

  # Trim, keep only E.164-shaped entries (skip the rest — never reject the batch), de-dup.
  defp normalize(phone_numbers) do
    phone_numbers
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&Regex.match?(@e164, &1))
    |> Enum.uniq()
  end

  # Size is checked on the RAW count, BEFORE filtering — so malformed padding can't smuggle an oversize batch.
  defp check_batch_size(phone_numbers) do
    if length(phone_numbers) > @max_batch, do: {:error, :batch_too_large}, else: :ok
  end

  # Per-user throttle, FAIL-CLOSED (unlike reports/OTP): the limit is a security control here, so a limiter
  # outage rejects rather than opening the enumeration oracle. `fail_open: false` makes the limiter surface
  # the outage instead of silently allowing.
  defp rate_limit(user_id) do
    case SharedInfra.RateLimiter.check_rate(%{
           "key" => "contacts_sync:" <> user_id,
           "limit" => @rate_limit,
           "window_seconds" => @rate_window_seconds,
           "fail_open" => false
         }) do
      :ok -> :ok
      {:error, :rate_limited, _retry} = limited -> limited
      _ -> {:error, :rate_limiter_unavailable}
    end
  end

  defp session(conn) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}) do
      {:ok, session}
    else
      _ -> {:error, :session_invalid}
    end
  end

  defp authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, "Bearer " <> token}
      _ -> {:error, :session_invalid}
    end
  end

  defp session_app(session), do: Map.get(session, :app_id)

  # --- responses ---

  defp batch_too_large(conn),
    do:
      ErrorResponse.invalid_request_with(
        conn,
        "contacts.batch_too_large",
        "Too many numbers in one sync",
        %{max: @max_batch}
      )

  defp rate_limited(conn, retry_after_seconds) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds))
    |> ErrorResponse.rate_limited("contacts.rate_limited")
  end

  defp limiter_unavailable(conn) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(@limiter_outage_retry))
    |> ErrorResponse.service_unavailable("contacts.unavailable")
  end

  defp unauthorized(conn),
    do: ErrorResponse.unauthorized(conn, "auth.session_invalid", "Invalid or missing session")
end
