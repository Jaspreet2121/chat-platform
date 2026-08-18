defmodule ApiGatewayWeb.LinkController do
  @moduledoc """
  QR device linking (099) — WhatsApp's model: THE PHONE APPROVES, NEVER THE BROWSER. The browser
  mints an anonymous link request and renders its QR; the phone (an authenticated app session) scans
  and approves; the browser's long-poll then collects a freshly-minted web session exactly once.

  Phishing/relay resistance comes from the shape of the flow, not the QR's content: the QR carries
  ONLY {link_id, nonce} — no tokens, nothing replayable; the tokens exist first at approve time,
  encrypted under a key derived from link_id + the server secret, retrievable once (atomic
  SET..GET consume), for 60 seconds, by whoever holds the poll_token the CREATING browser kept.
  A relayed QR therefore yields tokens only to the original browser, never to the relay.

  State lives in Redis (LinkStore seam, TTL 60s): pending → approved → consumed; expiry is the TTL.
  Audit lines (created / approved / consumed / expired-poll) never carry tokens or nonces.
  """
  use ApiGatewayWeb, :controller

  require Logger

  alias ApiGatewayWeb.ErrorResponse
  alias ApiGatewayWeb.LinkStore

  @qr_prefix "skifi-link:v1:"
  @link_ttl_seconds 60
  # Long-poll: ≤ 25s per request, re-checking Redis every second (test-shrinkable).
  @poll_window_ms 25_000
  @poll_interval_ms 1_000

  # Approve is the security-sensitive step: 5/min per USER, FAIL-CLOSED (registered in
  # RATE_LIMIT_POLICY.md; create/wait are per-IP pipelines in the router).
  @approve_limit 5
  @approve_window_seconds 60
  @limiter_outage_retry 30

  # POST /api/v1/link/qr — unauthenticated; mints the pending link request. Per-IP rate limit rides
  # the router pipeline (10/min).
  def create(conn, _params) do
    link_id = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    poll_token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    state = %{
      "state" => "pending",
      "nonce_hash" => hash(nonce),
      "poll_hash" => hash(poll_token),
      # Client fingerprint — audit context only, never an auth factor (a UA is trivially forged).
      "ua" => conn |> get_req_header("user-agent") |> List.first() |> truncate(120),
      "ip_hash" => conn.remote_ip |> :erlang.term_to_binary() |> hash(),
      "created_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    case LinkStore.put(key(link_id), Jason.encode!(state), @link_ttl_seconds) do
      :ok ->
        Logger.info("[link_qr] created link_id=#{link_id}")

        json(conn, %{
          link_id: link_id,
          qr_payload: @qr_prefix <> link_id <> ":" <> nonce,
          expires_in: @link_ttl_seconds,
          poll_token: poll_token
        })

      {:error, reason} ->
        Logger.warning("[link_qr] create failed (redis): #{inspect(reason)}")
        ErrorResponse.service_unavailable(conn, "link.unavailable")
    end
  end

  # GET /api/v1/link/qr/:link_id/wait?poll_token= — the creating browser's long-poll. Returns
  # {state} for pending/expired/consumed; {state: approved, session: {...}} EXACTLY ONCE.
  def wait(conn, %{"link_id" => link_id, "poll_token" => poll_token} = _params)
      when is_binary(link_id) and link_id != "" and is_binary(poll_token) and poll_token != "" do
    poll(conn, link_id, poll_token, System.monotonic_time(:millisecond) + poll_window_ms())
  end

  def wait(conn, _params), do: ErrorResponse.invalid_request(conn, "link.invalid_request")

  defp poll(conn, link_id, poll_token, deadline) do
    case LinkStore.get(key(link_id)) do
      :not_found ->
        Logger.info("[link_qr] poll on expired/unknown link_id=#{link_id}")
        json(conn, %{state: "expired"})

      {:ok, raw} ->
        state = Jason.decode!(raw)

        # The poll_token gates EVERY read — a wrong token is indistinguishable from an unknown link
        # (constant-time compare; no oracle for guessing).
        if secure_equal?(hash(poll_token), Map.get(state, "poll_hash")) do
          advance(conn, link_id, poll_token, state, deadline)
        else
          ErrorResponse.not_found(conn, "link.not_found", "Unknown link")
        end

      {:error, reason} ->
        Logger.warning("[link_qr] poll failed (redis): #{inspect(reason)}")
        ErrorResponse.service_unavailable(conn, "link.unavailable")
    end
  end

  defp advance(conn, link_id, poll_token, %{"state" => "pending"}, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      json(conn, %{state: "pending"})
    else
      Process.sleep(poll_interval_ms())
      poll(conn, link_id, poll_token, deadline)
    end
  end

  defp advance(conn, link_id, _poll_token, %{"state" => "approved"} = state, _deadline) do
    consumed =
      Jason.encode!(%{
        "state" => "consumed",
        "poll_hash" => Map.get(state, "poll_hash")
      })

    # ATOMIC single retrieval: both of two racing polls write "consumed", but SET..GET hands the
    # approved previous value to exactly one of them — only that one can decrypt and return tokens.
    case LinkStore.put_get(key(link_id), consumed, @link_ttl_seconds) do
      {:ok, {:was_present, previous_raw}} ->
        case Jason.decode!(previous_raw) do
          %{"state" => "approved", "payload_enc" => payload_enc} ->
            session = payload_enc |> decrypt(link_id) |> Jason.decode!()
            Logger.info("[link_qr] consumed link_id=#{link_id} session=#{session["session_id"]}")
            json(conn, %{state: "approved", session: session})

          _ ->
            json(conn, %{state: "consumed"})
        end

      _ ->
        json(conn, %{state: "consumed"})
    end
  end

  defp advance(conn, _link_id, _poll_token, _state, _deadline),
    do: json(conn, %{state: "consumed"})

  # POST /api/v1/link/approve — AUTHENTICATED with the phone's app session (a bearer sk_ credential
  # is not a session token and fails current_session — integrator keys can never approve links).
  def approve(conn, params) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         :ok <- require_confirm(params),
         {:ok, link_id, nonce} <- parse_qr_payload(Map.get(params, "qr_payload")),
         :ok <- approve_rate_limit(session.user_id),
         {:ok, state} <- load_pending(link_id, nonce) do
      device_name = device_name(params)

      case SharedInfra.AuthClient.link_device_session(%{
             "user_id" => session.user_id,
             # The PHONE session's tenant — the linked browser lives in the same app, never a default.
             "app_id" => Map.get(session, :app_id),
             "device_name" => device_name,
             "linked_by_device_id" => Map.get(session, :device_id)
           }) do
        {:ok, minted} ->
          finish_approval(conn, link_id, state, session, minted, device_name)

        _ ->
          ErrorResponse.service_unavailable(conn, "link.unavailable")
      end
    else
      {:error, :session_invalid} ->
        ErrorResponse.unauthorized(conn, "auth.session_invalid", "Session token is invalid")

      {:error, :auth_unavailable} ->
        ErrorResponse.service_unavailable(conn, "link.unavailable")

      {:error, :confirm_required} ->
        ErrorResponse.invalid_request(conn, "link.confirm_required")

      {:error, :malformed} ->
        ErrorResponse.invalid_request(conn, "link.invalid_payload")

      {:error, :expired} ->
        gone(conn, "link.expired", "This QR code has expired — generate a new one")

      {:error, :already_used} ->
        ErrorResponse.conflict(conn, "link.already_used", "This QR code was already used")

      {:error, :nonce_mismatch} ->
        ErrorResponse.invalid_request(conn, "link.invalid_payload")

      {:error, :rate_limited, retry_after_seconds} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds))
        |> ErrorResponse.rate_limited("link.rate_limited")

      {:error, :rate_limiter_unavailable} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(@limiter_outage_retry))
        |> ErrorResponse.service_unavailable("link.unavailable")

      {:error, :store_unavailable} ->
        ErrorResponse.service_unavailable(conn, "link.unavailable")

      _ ->
        ErrorResponse.invalid_request(conn, "link.invalid_request")
    end
  end

  defp finish_approval(conn, link_id, state, session, minted, device_name) do
    expires_at =
      DateTime.utc_now()
      |> DateTime.add(mget(minted, :access_token_expires_in_seconds) || 0, :second)
      |> DateTime.to_iso8601()

    session_payload =
      Jason.encode!(%{
        "access_token" => mget(minted, :access_token),
        "refresh_token" => mget(minted, :refresh_token),
        "expires_at" => expires_at,
        "session_id" => mget(minted, :session_id)
      })

    approved =
      Jason.encode!(%{
        "state" => "approved",
        "nonce_hash" => Map.get(state, "nonce_hash"),
        "poll_hash" => Map.get(state, "poll_hash"),
        "payload_enc" => encrypt(session_payload, link_id)
      })

    case LinkStore.put(key(link_id), approved, @link_ttl_seconds) do
      :ok ->
        # The phone's Linked-devices screen updates live (same user-topic bus the calls use).
        ApiGatewayWeb.Endpoint.broadcast("user:" <> session.user_id, "device_linked", %{
          session_id: mget(minted, :session_id),
          device_id: mget(minted, :device_id),
          device_name: device_name
        })

        Logger.info(
          "[link_qr] approved link_id=#{link_id} user=#{session.user_id} " <>
            "session=#{mget(minted, :session_id)} device=#{mget(minted, :device_id)}"
        )

        json(conn, %{
          linked: true,
          session_id: mget(minted, :session_id),
          device_name: device_name
        })

      {:error, reason} ->
        # The minted session is orphaned but harmless (revocable from Linked devices); the browser
        # simply never receives it and the link expires.
        Logger.warning("[link_qr] approve store write failed (redis): #{inspect(reason)}")
        ErrorResponse.service_unavailable(conn, "link.unavailable")
    end
  end

  defp load_pending(link_id, nonce) do
    case LinkStore.get(key(link_id)) do
      :not_found ->
        {:error, :expired}

      {:ok, raw} ->
        state = Jason.decode!(raw)

        cond do
          Map.get(state, "state") != "pending" ->
            {:error, :already_used}

          not secure_equal?(hash(nonce), Map.get(state, "nonce_hash")) ->
            {:error, :nonce_mismatch}

          true ->
            {:ok, state}
        end

      {:error, _reason} ->
        {:error, :store_unavailable}
    end
  end

  # qr_payload = "skifi-link:v1:<link_id>:<nonce>" — both segments base64url (no ':' possible).
  defp parse_qr_payload(@qr_prefix <> rest) when is_binary(rest) do
    case String.split(rest, ":", parts: 2) do
      [link_id, nonce] when link_id != "" and nonce != "" -> {:ok, link_id, nonce}
      _ -> {:error, :malformed}
    end
  end

  defp parse_qr_payload(_), do: {:error, :malformed}

  defp require_confirm(%{"confirm" => true}), do: :ok
  defp require_confirm(_params), do: {:error, :confirm_required}

  defp device_name(params) do
    case Map.get(params, "device_name") do
      name when is_binary(name) and name != "" -> String.slice(name, 0, 80)
      _ -> "Web"
    end
  end

  defp approve_rate_limit(user_id) do
    case SharedInfra.RateLimiter.check_rate(%{
           "key" => "link_approve:" <> user_id,
           "limit" => @approve_limit,
           "window_seconds" => @approve_window_seconds,
           "fail_open" => false
         }) do
      :ok -> :ok
      {:error, :rate_limited, _retry} = limited -> limited
      _ -> {:error, :rate_limiter_unavailable}
    end
  end

  # --- crypto ------------------------------------------------------------------------------------

  # AES-256-GCM under a key derived from the SERVER secret + link_id: a Redis snapshot alone (no
  # link_id, held only by the two live parties + this process) cannot yield tokens.
  defp encrypt(plaintext, link_id) do
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, derive_key(link_id), iv, plaintext, "link", true)

    Base.encode64(iv <> tag <> ciphertext)
  end

  defp decrypt(encoded, link_id) do
    <<iv::binary-size(12), tag::binary-size(16), ciphertext::binary>> = Base.decode64!(encoded)

    :crypto.crypto_one_time_aead(
      :aes_256_gcm,
      derive_key(link_id),
      iv,
      ciphertext,
      "link",
      tag,
      false
    )
  end

  defp derive_key(link_id),
    do: :crypto.hash(:sha256, ApiGatewayWeb.Endpoint.config(:secret_key_base) <> link_id)

  defp hash(value) when is_binary(value),
    do: Base.encode16(:crypto.hash(:sha256, value), case: :lower)

  defp hash(_), do: ""

  defp secure_equal?(a, b) when is_binary(a) and is_binary(b) and byte_size(a) == byte_size(b),
    do: :crypto.hash_equals(a, b)

  defp secure_equal?(_a, _b), do: false

  defp key(link_id), do: "link_qr:" <> link_id

  defp mget(map, k), do: Map.get(map, k) || Map.get(map, to_string(k))

  defp truncate(nil, _n), do: nil
  defp truncate(s, n) when is_binary(s), do: String.slice(s, 0, n)

  defp gone(conn, code, message) do
    conn
    |> put_status(:gone)
    |> json(%{error: %{code: code, message: message}})
  end

  defp poll_window_ms,
    do: Application.get_env(:api_gateway, :link_poll_window_ms, @poll_window_ms)

  defp poll_interval_ms,
    do: Application.get_env(:api_gateway, :link_poll_interval_ms, @poll_interval_ms)

  defp authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token = authorization] when token != "" -> {:ok, authorization}
      _ -> {:error, :session_invalid}
    end
  end
end
