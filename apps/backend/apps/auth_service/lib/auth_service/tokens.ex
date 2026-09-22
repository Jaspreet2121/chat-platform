defmodule AuthService.Tokens do
  @moduledoc """
  Access and refresh token boundary.

  The public boundary functions return contract placeholders by default.
  Database-backed refresh-token rotation and logout are opt-in so normal tests
  and local development do not require PostgreSQL.
  """

  alias AuthService.Accounts
  alias AuthService.DeviceSessions
  alias AuthService.RefreshTokens
  alias AuthService.Repo

  require Logger

  @token_version "v1"

  @type token_attrs :: map()
  @type result :: {:ok, map()} | {:error, atom()}

  @callback issue_pair(token_attrs()) :: result()
  @callback refresh(token_attrs()) :: result()
  @callback revoke(token_attrs()) :: result()

  def access_token_ttl_seconds, do: token_config(:access_token_ttl_seconds, 900)
  def refresh_token_ttl_seconds, do: token_config(:refresh_token_ttl_seconds, 2_592_000)
  def token_issuer, do: token_config(:issuer, "chat-platform")
  def token_audience, do: token_config(:audience, "chat-platform-clients")

  # Login session lifetime (the ACCESS token's own TTL): a real working session by default, or a long
  # "remember me" session. Env-overridable, read at runtime (no config.exs build-bake). Logout still
  # invalidates a long token — current_session checks the device session, which logout revokes.
  @default_session_ttl_seconds 10_800
  @remember_me_ttl_seconds 604_800

  # REFRESH REUSE GRACE (Part 3). A rotation that reached the database but whose RESPONSE never
  # reached the client leaves that client holding a token the server has already revoked. Retrying is
  # the only sane thing it can do, and until now the answer was `refresh_reused` — which Android
  # treats as a compromised chain and responds to by wiping its E2EE keys. A lost HTTP response is
  # not an attack, and it should not cost somebody their message history.
  #
  # Thirty seconds is sized for that and nothing else: a retry after a dropped response happens in
  # seconds, while a replayed token harvested from a log or a proxy arrives minutes to months later.
  # Outside the window reuse detection is exactly as it was.
  @refresh_grace_seconds 30

  @spec session_ttl_seconds(boolean()) :: pos_integer()
  def session_ttl_seconds(true),
    do: env_int("AUTH_SESSION_REMEMBER_TTL_SECONDS", @remember_me_ttl_seconds)

  def session_ttl_seconds(_remember_me),
    do: env_int("AUTH_SESSION_TTL_SECONDS", @default_session_ttl_seconds)

  @doc """
  How long after a rotation the just-rotated token is still accepted. Env-overridable so it can be
  taken to zero — restoring the old behaviour exactly — without a deploy of new code.
  """
  def refresh_grace_seconds,
    do: env_int_or_zero("AUTH_REFRESH_GRACE_SECONDS", @refresh_grace_seconds)

  defp env_int_or_zero(key, default) do
    case Integer.parse(System.get_env(key) || "") do
      {n, _} when n >= 0 -> n
      _ -> default
    end
  end

  defp env_int(key, default) do
    case Integer.parse(System.get_env(key) || "") do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  def issue_pair(_attrs), do: {:error, :not_implemented}

  def refresh(attrs) when is_map(attrs) do
    if refresh_token_rotation_persistence_enabled?() do
      refresh_persisted_token(attrs)
    else
      {:ok, placeholder_refresh_response()}
    end
  end

  def revoke(attrs) when is_map(attrs) do
    if logout_persistence_enabled?() do
      revoke_persisted_token(attrs)
    else
      {:ok, %{}}
    end
  end

  def prepare_issue_pair(attrs, opts \\ []) when is_map(attrs) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    secret = Keyword.get(opts, :secret, token_secret())
    user_id = get_attr(attrs, :user_id)
    device_id = get_attr(attrs, :device_id)
    session_id = get_attr(attrs, :session_id) || Ecto.UUID.generate()
    refresh_token_id = Ecto.UUID.generate()
    refresh_token = random_token()
    refresh_token_hash = hash_token(refresh_token, secret)

    # The login path passes :access_ttl_seconds (remember-me aware); other callers use the global default.
    access_token_ttl_seconds =
      Keyword.get(opts, :access_ttl_seconds) || access_token_ttl_seconds()

    refresh_token_ttl_seconds = refresh_token_ttl_seconds()
    access_expires_at = DateTime.add(now, access_token_ttl_seconds, :second)
    refresh_expires_at = DateTime.add(now, refresh_token_ttl_seconds, :second)

    # The app (tenant) this session belongs to. The existing login flow passes none → tenant zero.
    app_id = SharedInfra.Tenancy.app_id_or_default(get_attr(attrs, :app_id))

    claims = %{
      "typ" => "access",
      "sub" => user_id,
      "sid" => session_id,
      "did" => device_id,
      "app" => app_id,
      "iat" => DateTime.to_unix(now),
      "exp" => DateTime.to_unix(access_expires_at),
      "jti" => Ecto.UUID.generate(),
      "iss" => token_issuer(),
      "aud" => token_audience()
    }

    {:ok, access_token} = sign_claims(claims, secret: secret)

    {:ok,
     %{
       access_token: access_token,
       access_token_expires_in_seconds: access_token_ttl_seconds,
       refresh_token: refresh_token,
       refresh_token_expires_in_seconds: refresh_token_ttl_seconds,
       refresh_token_attrs: %{
         "id" => refresh_token_id,
         "user_id" => user_id,
         "device_id" => device_id,
         "token_hash" => refresh_token_hash,
         "expires_at" => refresh_expires_at
       },
       device_session_attrs: %{
         "user_id" => user_id,
         "device_id" => device_id,
         "device_name" => get_attr(attrs, :device_name),
         "platform" => get_attr(attrs, :platform) || "web",
         "refresh_token_hash" => refresh_token_hash,
         "last_seen_at" => now
       }
     }}
  end

  def prepare_refresh_rotation(refresh_token, existing_token_attrs, opts \\ [])
      when is_binary(refresh_token) and is_map(existing_token_attrs) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    secret = Keyword.get(opts, :secret, token_secret())
    new_token_id = Ecto.UUID.generate()
    new_refresh_token = random_token()
    new_refresh_token_hash = hash_token(new_refresh_token, secret)

    {:ok,
     %{
       presented_token_hash: hash_token(refresh_token, secret),
       new_refresh_token: new_refresh_token,
       new_refresh_token_attrs: %{
         "id" => new_token_id,
         "user_id" => get_attr(existing_token_attrs, :user_id),
         "device_id" => get_attr(existing_token_attrs, :device_id),
         "token_hash" => new_refresh_token_hash,
         "expires_at" => DateTime.add(now, refresh_token_ttl_seconds(), :second)
       },
       revoke_existing_attrs: %{
         "revoked_at" => now,
         "replaced_by_token_id" => new_token_id
       }
     }}
  end

  def sign_claims(claims, opts \\ []) when is_map(claims) do
    secret = Keyword.get(opts, :secret, token_secret())
    payload = Base.url_encode64(:erlang.term_to_binary(claims), padding: false)
    signature = sign_payload(payload, secret)

    {:ok, Enum.join([@token_version, payload, signature], ".")}
  end

  def verify_signed_token(token, opts \\ []) when is_binary(token) do
    secret = Keyword.get(opts, :secret, token_secret())

    with [@token_version, payload, signature] <- String.split(token, ".", parts: 3),
         true <- valid_signature?(payload, signature, secret),
         {:ok, binary_payload} <- Base.url_decode64(payload, padding: false),
         claims when is_map(claims) <- :erlang.binary_to_term(binary_payload, [:safe]),
         :ok <- verify_expiry(claims, Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)) do
      {:ok, claims}
    else
      false -> {:error, :invalid_signature}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_token}
    end
  rescue
    _ -> {:error, :invalid_token}
  end

  def hash_token(token, secret \\ token_secret()) when is_binary(token) do
    digest = :crypto.mac(:hmac, :sha256, secret, token)
    "sha256:" <> Base.encode16(digest, case: :lower)
  end

  defp refresh_persisted_token(attrs) do
    now = DateTime.utc_now()

    with {:repo, true} <- {:repo, repo_started?()},
         {:ok, refresh_token} <- submitted_refresh_token(attrs),
         token_hash <- hash_token(refresh_token),
         {:ok, existing_token, mode} <- get_active_refresh_token(token_hash, now),
         :ok <- valid_device?(existing_token, attrs),
         {:ok, device_session} <- get_active_device_session(existing_token),
         # SKIPPED ON THE GRACE PATH, and this is the subtle half of the feature. The session row
         # holds the CURRENT token's hash, so after a rotation the predecessor no longer matches it —
         # this guard would refuse the retry with `refresh_reused` even though the revoked_at check
         # had just forgiven it. Both guards have to agree or the window does nothing.
         :ok <- refresh_token_matches_session?(existing_token, device_session, mode),
         {:ok, _user} <- get_active_user(existing_token.user_id),
         {:ok, response} <- rotate_refresh_token(existing_token, device_session, now, mode) do
      if mode == :grace, do: log_refresh_grace(existing_token, attrs)
      {:ok, response}
    else
      {:repo, false} ->
        {:error, :repo_not_started}

      {:error, reason} ->
        log_refresh_failure(reason, attrs)
        {:error, reason}
    end
  end

  # THE LINE THAT WAS MISSING. A forced-logout investigation could not say WHY a refresh was refused:
  # tokens.ex logged nothing, and the gateway's request line records only the flattened HTTP code. The
  # cause atom is the whole point — without it the nine causes are indistinguishable in production.
  #
  # NEVER logs the refresh token, and never its full hash: a full hash is the lookup key for
  # refresh_tokens.token_hash, so logging one would put a working session identifier in the log
  # stream. Twelve hex characters correlate a token across lines without being usable to find the row.
  defp log_refresh_failure(reason, attrs) do
    Logger.warning(fn ->
      "[auth.refresh] refused reason=#{inspect(reason)} " <>
        "device_id=#{inspect(get_attr(attrs, :device_id))} " <>
        "token_hash_prefix=#{token_hash_prefix(attrs)} " <>
        "correlation_id=#{inspect(SharedInfra.Correlation.get())}"
    end)
  end

  # TWELVE HEX CHARACTERS, not twelve characters of the hash STRING. hash_token/1 returns an
  # algorithm-tagged value ("sha256:<hex>"), so slicing the raw string spent seven characters on the
  # tag and left five hex digits — enough collisions to make correlating a token across log lines
  # unreliable, which is the one job this field has. Strip the tag first, then take twelve.
  #
  # Still never the full hash: that value is the lookup key for refresh_tokens.token_hash, so logging
  # it would put a working session identifier in the log stream.
  defp token_hash_prefix(attrs) do
    case submitted_refresh_token(attrs) do
      {:ok, refresh_token} ->
        refresh_token |> hash_token() |> hash_digits() |> String.slice(0, 12)

      _ ->
        "none"
    end
  rescue
    _ -> "none"
  end

  defp hash_digits(hash) when is_binary(hash) do
    case String.split(hash, ":", parts: 2) do
      [_algorithm, digits] -> digits
      [digits] -> digits
    end
  end

  defp revoke_persisted_token(attrs) do
    now = DateTime.utc_now()

    with {:repo, true} <- {:repo, repo_started?()},
         {:ok, refresh_token} <- submitted_refresh_token(attrs),
         token_hash <- hash_token(refresh_token),
         # LOGOUT TAKES THE ACTIVE TOKEN ONLY. A grace-eligible predecessor is deliberately not
         # accepted here: it has already been superseded, and signing out with it would revoke a row
         # that is no longer the session's, leaving the live one alive. `:active` in the match is
         # what makes that a refusal rather than a silent half-logout.
         {:ok, existing_token, :active} <- get_active_refresh_token(token_hash, now),
         {:ok, _response} <- revoke_refresh_token_for_logout(existing_token, now) do
      # WHO was just signed out, from the AUTHORITATIVE row (works even when the access token already
      # expired) — the gateway uses this to sever the device's live socket (realtime session revocation).
      {:ok, %{user_id: existing_token.user_id, device_id: existing_token.device_id}}
    else
      {:repo, false} ->
        {:error, :repo_not_started}

      # LOGOUT KEEPS ITS OLD SHAPE. It shares get_active_refresh_token/2 with refresh, so it now sees
      # the new atoms too — but the distinction exists to tell a CLIENT how to react to a failed
      # ROTATION, and there is no such decision to make when signing out. Folding them back keeps
      # logout's contract byte-identical (401 auth.refresh_invalid) instead of leaking a 400 through
      # the gateway's catch-all.
      {:error, reason} when reason in [:refresh_expired, :refresh_reused, :session_revoked] ->
        {:error, :refresh_invalid}

      # A grace-eligible token presented to LOGOUT. Same answer a reused one has always given.
      {:ok, _token, :grace} ->
        {:error, :refresh_invalid}

      {:error, _reason} = error ->
        error
    end
  end

  # THE SAME CHECKS, IN THE SAME ORDER — only the error atom differs now. A client that is merely
  # past its expiry needs to re-login; a client presenting an already-rotated token might have been
  # replayed. Collapsing both into one code is what forced Android to wipe E2EE keys on an ordinary
  # expiry, because a wipe is the only safe response to an ambiguous "your token is bad".
  defp get_active_refresh_token(token_hash, now) do
    case RefreshTokens.get_by_token_hash(token_hash) do
      nil ->
        # Unknown hash: could be a forgery, a token from a wiped database, or a typo. Nothing here
        # says "expired", so it stays the conservative catch-all.
        {:error, :refresh_invalid}

      %{revoked_at: nil, expires_at: expires_at} = refresh_token when not is_nil(expires_at) ->
        if DateTime.compare(expires_at, now) == :gt do
          {:ok, refresh_token, :active}
        else
          {:error, :refresh_expired}
        end

      # Revoked, i.e. ALREADY ROTATED (rotation sets revoked_at + replaced_by_token_id) or logged out.
      # Presenting one is chain reuse: benign if a response was lost in flight, hostile if replayed.
      # THE GRACE WINDOW is what tells those two apart, and the only evidence available is WHEN. A
      # retry after a dropped response lands within seconds; a replay does not. A token revoked by
      # LOGOUT has no successor, so `replaced_by_token_id` is what keeps "I signed out" from being
      # re-admitted here — signing out must mean signed out, immediately.
      %{revoked_at: revoked_at, replaced_by_token_id: replaced_by} = refresh_token
      when not is_nil(revoked_at) and not is_nil(replaced_by) ->
        # `grace > 0` is checked SEPARATELY rather than folded into the comparison. DateTime.diff/2
        # truncates to whole seconds, so a replay in the same second as its rotation has a diff of
        # zero — and `0 <= 0` would have admitted it even with the window turned off. Zero has to
        # mean disabled, or the env override cannot restore the old behaviour.
        grace = refresh_grace_seconds()

        if grace > 0 and DateTime.diff(now, revoked_at) <= grace do
          {:ok, refresh_token, :grace}
        else
          {:error, :refresh_reused}
        end

      %{revoked_at: revoked_at} when not is_nil(revoked_at) ->
        {:error, :refresh_reused}

      # A row with no expires_at at all — malformed, never issued by prepare_issue_pair.
      _ ->
        {:error, :refresh_invalid}
    end
  end

  defp valid_device?(existing_token, attrs) do
    submitted_device_id = get_attr(attrs, :device_id)

    if submitted_device_id == existing_token.device_id do
      :ok
    else
      {:error, :refresh_invalid}
    end
  end

  # The device session is GONE or explicitly revoked — a sign-out, a "sign out everywhere else", or an
  # admin revoke. Distinct from expiry: the session was taken away, so the client should treat it as a
  # compromise-grade event rather than a routine re-login. A missing row is reported the same way; from
  # the device's side the two are indistinguishable, and both mean "this session no longer exists".
  defp get_active_device_session(existing_token) do
    case DeviceSessions.get_device_session(existing_token.user_id, existing_token.device_id) do
      nil ->
        {:error, :session_revoked}

      %{revoked_at: revoked_at} when not is_nil(revoked_at) ->
        {:error, :session_revoked}

      device_session ->
        {:ok, device_session}
    end
  end

  # The session's CURRENT hash is not this token — another rotation has happened since. Same class as a
  # revoked row (cause 3): the chain moved on without this token.
  defp refresh_token_matches_session?(_existing_token, _device_session, :grace), do: :ok

  defp refresh_token_matches_session?(existing_token, device_session, _mode) do
    if existing_token.token_hash == device_session.refresh_token_hash do
      :ok
    else
      {:error, :refresh_reused}
    end
  end

  # A grace hit is NOT a failure, so it does not go through log_refresh_failure/2 — but it is the one
  # thing an operator needs to see if the window is ever suspected of hiding a real replay. Same
  # redaction rules: twelve hex characters, never the token, never the full hash.
  defp log_refresh_grace(existing_token, attrs) do
    Logger.info(fn ->
      "[auth.refresh] GRACE accepted a just-rotated token " <>
        "window_seconds=#{refresh_grace_seconds()} " <>
        "device_id=#{inspect(existing_token.device_id)} " <>
        "token_hash_prefix=#{token_hash_prefix(attrs)} " <>
        "correlation_id=#{inspect(SharedInfra.Correlation.get())}"
    end)
  end

  defp get_active_user(user_id) do
    case Accounts.get_user(user_id) do
      nil -> {:error, :refresh_invalid}
      %{status: "active"} = user -> {:ok, user}
      _ -> {:error, :refresh_invalid}
    end
  end

  defp rotate_refresh_token(existing_token, device_session, now, mode) do
    Repo.transaction(fn ->
      # RACE SAFETY, and it matters most on the grace path. A client whose response was lost often
      # retries more than once — two in-flight replays of the SAME token would otherwise both read
      # the session row, both mint, and both write `refresh_token_hash`, leaving the session pointing
      # at one token while the other client holds the other. A transaction-scoped advisory lock on
      # the PRESENTED token's hash serialises them, so the second sees the first's committed state.
      # Transaction-scoped means it is released by commit or rollback with nothing to clean up.
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [existing_token.token_hash])

      token_attrs = %{
        "user_id" => existing_token.user_id,
        "session_id" => device_session.id,
        "device_id" => existing_token.device_id,
        "device_name" => device_session.device_name,
        "platform" => device_session.platform
      }

      with {:ok, token_pair} <- prepare_issue_pair(token_attrs, now: now),
           {:ok, new_refresh_token} <-
             RefreshTokens.create_refresh_token(token_pair.refresh_token_attrs),
           # ON THE GRACE PATH THE OLD ROW IS LEFT ALONE. It is already revoked, and its
           # `replaced_by_token_id` already names the successor from the rotation whose response was
           # lost. Overwriting that pointer would rewrite the chain to hide the very event an
           # investigator would be looking for, and re-stamping `revoked_at` would slide the window
           # forward on every retry — a token that could be replayed indefinitely as long as someone
           # kept replaying it.
           {:ok, _old_refresh_token} <-
             maybe_revoke_predecessor(existing_token, new_refresh_token, now, mode),
           {:ok, _device_session} <-
             DeviceSessions.update_device_session(device_session, %{
               "refresh_token_hash" => token_pair.refresh_token_attrs["token_hash"],
               "last_seen_at" => now,
               "revoked_at" => nil
             }) do
        %{
          access_token: token_pair.access_token,
          access_token_expires_in_seconds: token_pair.access_token_expires_in_seconds,
          refresh_token: token_pair.refresh_token,
          refresh_token_expires_in_seconds: token_pair.refresh_token_expires_in_seconds
        }
      else
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:refresh_invalid)
      end
    end)
    |> case do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_revoke_predecessor(existing_token, _new_refresh_token, _now, :grace),
    do: {:ok, existing_token}

  defp maybe_revoke_predecessor(existing_token, new_refresh_token, now, _mode),
    do:
      RefreshTokens.revoke_refresh_token(existing_token, %{
        "revoked_at" => now,
        "replaced_by_token_id" => new_refresh_token.id
      })

  defp revoke_refresh_token_for_logout(existing_token, now) do
    Repo.transaction(fn ->
      with {:ok, _refresh_token} <-
             RefreshTokens.revoke_refresh_token(existing_token, %{"revoked_at" => now}),
           {:ok, _device_session} <- revoke_device_session(existing_token, now) do
        %{}
      else
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:refresh_invalid)
      end
    end)
    |> case do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp revoke_device_session(existing_token, now) do
    case DeviceSessions.get_device_session(existing_token.user_id, existing_token.device_id) do
      nil ->
        {:ok, nil}

      device_session ->
        DeviceSessions.update_device_session(device_session, %{"revoked_at" => now})
    end
  end

  defp submitted_refresh_token(attrs) do
    refresh_token = get_attr(attrs, :refresh_token)

    if is_binary(refresh_token) and refresh_token != "" do
      {:ok, refresh_token}
    else
      {:error, :invalid_request}
    end
  end

  defp refresh_token_rotation_persistence_enabled? do
    Application.get_env(:auth_service, :refresh_token_rotation_persistence, false) ||
      System.get_env("AUTH_REFRESH_TOKEN_DB_BACKED") == "true"
  end

  defp logout_persistence_enabled? do
    Application.get_env(:auth_service, :logout_persistence, false) ||
      System.get_env("AUTH_LOGOUT_DB_BACKED") == "true"
  end

  defp repo_started?, do: not is_nil(Process.whereis(AuthService.Repo))

  defp placeholder_refresh_response do
    %{
      access_token: "new_access_token_placeholder",
      access_token_expires_in_seconds: 900,
      refresh_token: "new_refresh_token_placeholder",
      refresh_token_expires_in_seconds: 2_592_000
    }
  end

  defp verify_expiry(%{"exp" => expires_at}, now) when is_integer(expires_at) do
    if expires_at > DateTime.to_unix(now), do: :ok, else: {:error, :expired}
  end

  defp verify_expiry(_claims, _now), do: {:error, :missing_expiry}

  defp valid_signature?(payload, signature, secret) do
    expected_signature = sign_payload(payload, secret)

    byte_size(signature) == byte_size(expected_signature) &&
      :crypto.hash_equals(signature, expected_signature)
  end

  defp sign_payload(payload, secret) do
    :crypto.mac(:hmac, :sha256, secret, payload)
    |> Base.url_encode64(padding: false)
  end

  defp random_token do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end

  defp token_secret do
    Application.get_env(:auth_service, :token_secret) ||
      System.get_env("TOKEN_SECRET") ||
      System.get_env("SECRET_KEY_BASE") ||
      "local-token-secret-change-before-production"
  end

  defp token_config(key, default) do
    :auth_service
    |> Application.get_env(:tokens, [])
    |> Keyword.get(key, default)
  end

  defp get_attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end
end
