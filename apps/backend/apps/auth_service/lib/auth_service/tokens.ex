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

  @spec session_ttl_seconds(boolean()) :: pos_integer()
  def session_ttl_seconds(true),
    do: env_int("AUTH_SESSION_REMEMBER_TTL_SECONDS", @remember_me_ttl_seconds)

  def session_ttl_seconds(_remember_me),
    do: env_int("AUTH_SESSION_TTL_SECONDS", @default_session_ttl_seconds)

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
         {:ok, existing_token} <- get_active_refresh_token(token_hash, now),
         :ok <- valid_device?(existing_token, attrs),
         {:ok, device_session} <- get_active_device_session(existing_token),
         :ok <- refresh_token_matches_session?(existing_token, device_session),
         {:ok, _user} <- get_active_user(existing_token.user_id),
         {:ok, response} <- rotate_refresh_token(existing_token, device_session, now) do
      {:ok, response}
    else
      {:repo, false} -> {:error, :repo_not_started}
      {:error, :refresh_invalid} -> {:error, :refresh_invalid}
      {:error, _reason} = error -> error
    end
  end

  defp revoke_persisted_token(attrs) do
    now = DateTime.utc_now()

    with {:repo, true} <- {:repo, repo_started?()},
         {:ok, refresh_token} <- submitted_refresh_token(attrs),
         token_hash <- hash_token(refresh_token),
         {:ok, existing_token} <- get_active_refresh_token(token_hash, now),
         {:ok, _response} <- revoke_refresh_token_for_logout(existing_token, now) do
      # WHO was just signed out, from the AUTHORITATIVE row (works even when the access token already
      # expired) — the gateway uses this to sever the device's live socket (realtime session revocation).
      {:ok, %{user_id: existing_token.user_id, device_id: existing_token.device_id}}
    else
      {:repo, false} -> {:error, :repo_not_started}
      {:error, :refresh_invalid} -> {:error, :refresh_invalid}
      {:error, _reason} = error -> error
    end
  end

  defp get_active_refresh_token(token_hash, now) do
    case RefreshTokens.get_by_token_hash(token_hash) do
      nil ->
        {:error, :refresh_invalid}

      %{revoked_at: nil, expires_at: expires_at} = refresh_token when not is_nil(expires_at) ->
        if DateTime.compare(expires_at, now) == :gt do
          {:ok, refresh_token}
        else
          {:error, :refresh_invalid}
        end

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

  defp get_active_device_session(existing_token) do
    case DeviceSessions.get_device_session(existing_token.user_id, existing_token.device_id) do
      nil ->
        {:error, :refresh_invalid}

      %{revoked_at: revoked_at} when not is_nil(revoked_at) ->
        {:error, :refresh_invalid}

      device_session ->
        {:ok, device_session}
    end
  end

  defp refresh_token_matches_session?(existing_token, device_session) do
    if existing_token.token_hash == device_session.refresh_token_hash do
      :ok
    else
      {:error, :refresh_invalid}
    end
  end

  defp get_active_user(user_id) do
    case Accounts.get_user(user_id) do
      nil -> {:error, :refresh_invalid}
      %{status: "active"} = user -> {:ok, user}
      _ -> {:error, :refresh_invalid}
    end
  end

  defp rotate_refresh_token(existing_token, device_session, now) do
    Repo.transaction(fn ->
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
           {:ok, _old_refresh_token} <-
             RefreshTokens.revoke_refresh_token(existing_token, %{
               "revoked_at" => now,
               "replaced_by_token_id" => new_refresh_token.id
             }),
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
