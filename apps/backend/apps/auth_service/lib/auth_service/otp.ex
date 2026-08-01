defmodule AuthService.OTP do
  @moduledoc """
  OTP request and verification boundary.

  The public request/verify functions return contract placeholders by default.
  Database-backed OTP request and verify paths are opt-in so normal tests and
  local development do not require PostgreSQL.
  """

  alias AuthService.Accounts
  alias AuthService.DeviceSessions
  alias AuthService.RefreshTokens
  alias AuthService.Repo
  alias AuthService.Tokens
  alias AuthService.VerificationCodes

  @default_code_digits 6
  @default_ttl_seconds 300
  @default_retry_after_seconds 60

  @type request_attrs :: map()
  @type verify_attrs :: map()
  @type result :: {:ok, map()} | {:error, atom()}

  @callback request_otp(request_attrs()) :: result()
  @callback verify_otp(verify_attrs()) :: result()

  def generate_code(digits \\ @default_code_digits)

  def generate_code(digits) when is_integer(digits) and digits in 4..10 do
    limit = integer_power(10, digits)

    :crypto.strong_rand_bytes(8)
    |> :binary.decode_unsigned()
    |> rem(limit)
    |> Integer.to_string()
    |> String.pad_leading(digits, "0")
  end

  def hash_code(destination, purpose, code, secret \\ otp_secret()) do
    digest =
      :crypto.mac(:hmac, :sha256, secret, [
        normalize(destination),
        "|",
        normalize(purpose),
        "|",
        to_string(code)
      ])

    "sha256:" <> Base.encode16(digest, case: :lower)
  end

  def valid_code?(destination, purpose, code, code_hash, secret \\ otp_secret())

  def valid_code?(destination, purpose, code, code_hash, secret) when is_binary(code_hash) do
    expected_hash = hash_code(destination, purpose, code, secret)

    byte_size(expected_hash) == byte_size(code_hash) &&
      :crypto.hash_equals(expected_hash, code_hash)
  end

  def valid_code?(_destination, _purpose, _code, _code_hash, _secret), do: false

  def build_verification_attrs(attrs, opts \\ []) when is_map(attrs) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    ttl_seconds = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
    code = Map.get(attrs, :code) || Map.get(attrs, "code") || generate_code()
    destination = Map.get(attrs, :destination) || Map.get(attrs, "destination")
    purpose = Map.get(attrs, :purpose) || Map.get(attrs, "purpose") || "login"
    secret = Keyword.get(opts, :secret, otp_secret())

    %{
      "purpose" => purpose,
      "destination" => destination,
      "code_hash" => hash_code(destination, purpose, code, secret),
      "attempts" => 0,
      "expires_at" => DateTime.add(now, ttl_seconds, :second)
    }
  end

  def prepare_request(attrs, opts \\ []) when is_map(attrs) do
    with {:ok, destination, delivery_method} <- destination(attrs) do
      now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
      ttl_seconds = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
      retry_after_seconds = Keyword.get(opts, :retry_after_seconds, @default_retry_after_seconds)
      otp_request_id = Keyword.get(opts, :otp_request_id) || Ecto.UUID.generate()
      purpose = get_attr(attrs, :purpose) || "login"
      code = Keyword.get(opts, :code) || get_attr(attrs, :code) || generate_code()
      secret = Keyword.get(opts, :secret, otp_secret())

      verification_attrs =
        attrs
        |> Map.merge(%{
          "id" => otp_request_id,
          "destination" => destination,
          "purpose" => purpose,
          "code" => code
        })
        |> build_verification_attrs(
          now: now,
          ttl_seconds: ttl_seconds,
          secret: secret
        )
        |> Map.put("id", otp_request_id)
        |> Map.put("consumed_at", nil)

      {:ok,
       %{
         response: %{
           otp_request_id: otp_request_id,
           delivery_method: delivery_method,
           expires_in_seconds: ttl_seconds,
           retry_after_seconds: retry_after_seconds
         },
         verification_attrs: verification_attrs,
         # Internal only — the PLAINTEXT code + destination for delivery. NEVER in `response` or the DB.
         delivery: %{destination: destination, code: code, method: delivery_method}
       }}
    end
  end

  def request_otp(attrs) when is_map(attrs) do
    if otp_request_persistence_enabled?() do
      request_persisted_otp(attrs)
    else
      {:ok, placeholder_response()}
    end
  end

  def verify_otp(attrs) when is_map(attrs) do
    if otp_verify_persistence_enabled?() do
      verify_persisted_otp(attrs)
    else
      {:ok, placeholder_verify_response()}
    end
  end

  defp request_persisted_otp(attrs) do
    with {:ok, request} <- prepare_request(attrs),
         {:repo, true} <- {:repo, repo_started?()},
         {:ok, verification_code} <-
           AuthService.VerificationCodes.create_verification_code(request.verification_attrs) do
      # Deliver AFTER a successful persist. Flag-gated + resilient (failure logged, request still ok).
      AuthService.OtpDelivery.deliver(
        request.delivery.destination,
        request.delivery.code,
        request.delivery.method
      )

      response = %{request.response | otp_request_id: verification_code.id}
      # echo mode (LOCAL/STAGING) adds :debug_code; default "none" returns it unchanged.
      {:ok, AuthService.OtpDelivery.echo_code(response, request.delivery.code)}
    else
      {:repo, false} -> {:error, :repo_not_started}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_request}
    end
  end

  defp verify_persisted_otp(attrs) do
    now = DateTime.utc_now()

    with {:repo, true} <- {:repo, repo_started?()},
         {:ok, otp_request_id} <- otp_request_id(attrs),
         {:ok, otp_code} <- submitted_otp(attrs),
         {:ok, destination, delivery_method} <- destination(attrs),
         purpose <- get_attr(attrs, :purpose) || "login",
         {:ok, verification_code} <-
           get_verification_code(otp_request_id, destination, purpose, now),
         true <-
           valid_code?(
             verification_code.destination,
             verification_code.purpose,
             otp_code,
             verification_code.code_hash
           ),
         {:ok, response} <-
           persist_verified_otp(attrs, destination, delivery_method, verification_code, now) do
      {:ok, response}
    else
      {:repo, false} -> {:error, :repo_not_started}
      false -> {:error, :otp_invalid}
      {:error, :otp_invalid} -> {:error, :otp_invalid}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_request}
    end
  end

  defp get_verification_code(otp_request_id, destination, purpose, now) do
    with %{} = verification_code <- VerificationCodes.get_verification_code(otp_request_id),
         :ok <- valid_verification_code?(verification_code, destination, purpose, now) do
      {:ok, verification_code}
    else
      _ -> {:error, :otp_invalid}
    end
  rescue
    Ecto.Query.CastError -> {:error, :otp_invalid}
  end

  defp valid_verification_code?(verification_code, destination, purpose, now) do
    cond do
      verification_code.destination != destination ->
        {:error, :otp_invalid}

      verification_code.purpose != purpose ->
        {:error, :otp_invalid}

      not is_nil(verification_code.consumed_at) ->
        {:error, :otp_invalid}

      DateTime.compare(verification_code.expires_at, now) != :gt ->
        {:error, :otp_invalid}

      true ->
        :ok
    end
  end

  defp persist_verified_otp(attrs, destination, delivery_method, verification_code, now) do
    Repo.transaction(fn ->
      with {:ok, user} <- find_or_create_user(destination, delivery_method),
           existing_session <-
             DeviceSessions.get_device_session(user.id, get_attr(attrs, :device_id)),
           session_id <- session_id(existing_session),
           {:ok, token_pair} <-
             Tokens.prepare_issue_pair(token_attrs(attrs, user.id, session_id),
               now: now,
               access_ttl_seconds: Tokens.session_ttl_seconds(remember_me?(attrs))
             ),
           {:ok, device_session} <-
             create_or_update_device_session(existing_session, session_id, token_pair),
           {:ok, _refresh_token} <-
             RefreshTokens.create_refresh_token(token_pair.refresh_token_attrs),
           {:ok, _verification_code} <-
             VerificationCodes.consume_verification_code(verification_code, %{
               "consumed_at" => now
             }) do
        %{
          user_id: user.id,
          session_id: device_session.id,
          access_token: token_pair.access_token,
          access_token_expires_in_seconds: token_pair.access_token_expires_in_seconds,
          refresh_token: token_pair.refresh_token,
          refresh_token_expires_in_seconds: token_pair.refresh_token_expires_in_seconds
        }
      else
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:invalid_request)
      end
    end)
    |> case do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_or_create_user(destination, "sms") do
    case Accounts.get_by_phone_number(destination) do
      nil ->
        Accounts.create_user(%{
          "id" => Ecto.UUID.generate(),
          "phone_number" => destination,
          "status" => "active"
        })

      user ->
        {:ok, user}
    end
  end

  # EMAIL IS NOT A LOGIN METHOD. Refused explicitly rather than left as a latent path:
  #   * `users_auth.email` is now settable by users as an UNVERIFIED contact detail (see
  #     AuthService.Accounts.update_email) — nobody proves they own it, so accepting it as an OTP
  #     destination would let anyone claim a stranger's address and receive a session for it;
  #   * this flow carries NO app_id (the whole OTP path is app-blind), while email is per-tenant
  #     unique since 048 — so a lookup here cannot even name which tenant's account it means.
  # Making email a login method requires a verification flow AND a tenanted OTP path. Until both
  # exist, this fails closed. Unreachable from every public surface today (the gateway mandates
  # phone_number on otp/request and otp/verify) — this is defence in depth, not a live regression.
  defp find_or_create_user(_destination, "email"), do: {:error, :email_login_unsupported}

  defp create_or_update_device_session(nil, session_id, token_pair) do
    token_pair.device_session_attrs
    |> Map.put("id", session_id)
    |> Map.put("revoked_at", nil)
    |> DeviceSessions.create_device_session()
  end

  defp create_or_update_device_session(existing_session, _session_id, token_pair) do
    attrs = Map.put(token_pair.device_session_attrs, "revoked_at", nil)

    DeviceSessions.update_device_session(existing_session, attrs)
  end

  defp token_attrs(attrs, user_id, session_id) do
    %{
      "user_id" => user_id,
      "session_id" => session_id,
      "device_id" => get_attr(attrs, :device_id),
      "device_name" => get_attr(attrs, :device_name) || get_in(attrs, ["device", "device_name"]),
      "platform" => get_attr(attrs, :platform) || get_in(attrs, ["device", "platform"]) || "web"
    }
  end

  # "Remember me" opt-in (accepts a boolean or the string "true"/"1"). Selects the 7-day session TTL.
  defp remember_me?(attrs) do
    case get_attr(attrs, :remember_me) do
      true -> true
      value when is_binary(value) -> value in ["true", "1", "yes"]
      _ -> false
    end
  end

  defp session_id(nil), do: Ecto.UUID.generate()
  defp session_id(existing_session), do: existing_session.id

  defp placeholder_response do
    %{
      otp_request_id: "otp_req_placeholder",
      delivery_method: "sms",
      expires_in_seconds: @default_ttl_seconds,
      retry_after_seconds: @default_retry_after_seconds
    }
  end

  defp placeholder_verify_response do
    %{
      user_id: "user_placeholder",
      session_id: "sess_placeholder",
      access_token: "access_token_placeholder",
      access_token_expires_in_seconds: 900,
      refresh_token: "refresh_token_placeholder",
      refresh_token_expires_in_seconds: 2_592_000
    }
  end

  defp otp_request_persistence_enabled? do
    Application.get_env(:auth_service, :otp_request_persistence, false) ||
      System.get_env("AUTH_OTP_REQUEST_DB_BACKED") == "true"
  end

  defp otp_verify_persistence_enabled? do
    Application.get_env(:auth_service, :otp_verify_persistence, false) ||
      System.get_env("AUTH_OTP_VERIFY_DB_BACKED") == "true"
  end

  defp repo_started?, do: not is_nil(Process.whereis(AuthService.Repo))

  defp otp_secret do
    Application.get_env(:auth_service, :otp_secret) ||
      System.get_env("OTP_SECRET") ||
      "local-otp-secret-change-before-production"
  end

  defp destination(attrs) do
    cond do
      present?(get_attr(attrs, :phone_number)) ->
        {:ok, normalize_destination(get_attr(attrs, :phone_number)), "sms"}

      present?(get_attr(attrs, :email)) ->
        {:ok, normalize_destination(get_attr(attrs, :email)), "email"}

      true ->
        {:error, :unsupported_destination}
    end
  end

  defp otp_request_id(attrs) do
    case Ecto.UUID.cast(get_attr(attrs, :otp_request_id)) do
      {:ok, otp_request_id} -> {:ok, otp_request_id}
      :error -> {:error, :invalid_request}
    end
  end

  defp submitted_otp(attrs) do
    otp_code = get_attr(attrs, :otp_code) || get_attr(attrs, :otp)

    if present?(otp_code) do
      {:ok, to_string(otp_code)}
    else
      {:error, :invalid_request}
    end
  end

  defp get_attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp present?(value), do: not is_nil(value) and value != ""

  defp integer_power(base, exponent), do: round(:math.pow(base, exponent))

  defp normalize_destination(value) do
    value
    |> to_string()
    |> String.trim()
  end

  defp normalize(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end
end
