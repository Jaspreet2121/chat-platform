defmodule SharedInfra.Apns.ProviderToken do
  @moduledoc """
  The APNs PROVIDER AUTHENTICATION TOKEN — an ES256 JWT signed with an Apple `.p8` key, sent as
  `authorization: bearer <jwt>` on every push.

  Token auth rather than certificate auth, deliberately: one key serves every topic and every
  environment, it does not expire annually, and it is a file plus two identifiers rather than a
  keychain export. The alert topic and the VoIP topic are the same app and take the same token.

  ## The refresh rule is Apple's, and it cuts both ways

  APNs REJECTS a token older than one hour (`ExpiredProviderToken`) and also rejects a provider that
  mints a fresh one on every push (`TooManyProviderTokenUpdates`). So the token must be cached and
  reused, and the cache must expire before Apple does. Fifty minutes leaves ten minutes of slack for
  a clock that is a little ahead of Apple's, which is the failure this margin exists for — APNs
  validates `iat` against ITS clock, not ours.

  Cached in `:persistent_term` rather than a GenServer: it is read on every push from whatever
  process is fanning out, written a few times a day, and a GenServer would put a message queue in
  front of the hot path to protect a value that one extra signature would regenerate anyway.

  ## What is a secret and what is not

  The `.p8` is mounted read-only into the container and read from disk at first use — never in git,
  never in the image, never logged. The Key ID and Team ID are not secrets (they appear in the JWT
  header and payload in the clear) but they live beside it in the environment so all three rotate
  together.
  """

  require Logger

  @cache_key {__MODULE__, :token}

  # Apple rejects anything older than 60 minutes. 50 leaves slack for clock skew against THEIR clock.
  @refresh_after_seconds 3_000

  @doc """
  `{:ok, jwt}` or `{:error, reason}`. Returns the cached token until it is due for refresh.

  `:apns_not_configured` is a normal, quiet outcome — it is what every environment without an Apple
  key returns, and the sender treats it as "iOS push is off" rather than as a failure.
  """
  def fetch do
    case :persistent_term.get(@cache_key, nil) do
      {jwt, minted_at} ->
        if System.system_time(:second) - minted_at < @refresh_after_seconds,
          do: {:ok, jwt},
          else: mint()

      _ ->
        mint()
    end
  end

  @doc "Drop the cached token. For a key rotation without a restart, and for tests."
  def reset, do: :persistent_term.erase(@cache_key)

  @doc """
  Sign a token from explicit material, bypassing both the config and the cache. The pure core — this
  is what a test drives with a throwaway key.

  ES256 on OTP's own crypto rather than a JWT library: signing one fixed-shape token needs a PEM
  parse, one `:crypto.sign` and a DER unpacking, and none of the three is worth a new dependency in
  shared_infra — which every release in the umbrella carries.
  """
  def sign(pem, key_id, team_id, now \\ System.system_time(:second))
      when is_binary(pem) and is_binary(key_id) and is_binary(team_id) do
    # `kid` in the HEADER, `iss` in the PAYLOAD. Apple checks both, and swapping them is the classic
    # first-attempt mistake — it fails as InvalidProviderToken with nothing saying which half.
    header = base64url(Jason.encode!(%{"alg" => "ES256", "kid" => key_id, "typ" => "JWT"}))
    payload = base64url(Jason.encode!(%{"iss" => team_id, "iat" => now}))
    signing_input = header <> "." <> payload

    [entry] = :public_key.pem_decode(pem)
    private_key = :public_key.pem_entry_decode(entry)

    signature =
      :crypto.sign(:ecdsa, :sha256, signing_input, [elem(private_key, 2), :secp256r1])

    {:ok, signing_input <> "." <> base64url(raw_signature(signature))}
  rescue
    error ->
      # The key material is in scope here. Log the EXCEPTION TYPE only — an inspect of the struct
      # could carry the parsed key into the log stream.
      Logger.error("apns: provider token signing failed (#{inspect(error.__struct__)})")
      {:error, :apns_token_signing_failed}
  end

  @doc "Is an Apple key configured at all? The sender's on/off switch."
  def configured? do
    case config() do
      {:ok, _key_path, _key_id, _team_id} -> true
      _ -> false
    end
  end

  @doc "`{:ok, team_id}` — the Team ID, which the apple-app-site-association file also needs."
  def team_id do
    case config() do
      {:ok, _key_path, _key_id, team_id} -> {:ok, team_id}
      error -> error
    end
  end

  defp mint do
    with {:ok, key_path, key_id, team_id} <- config(),
         {:ok, pem} <- read_key(key_path),
         {:ok, jwt} <- sign(pem, key_id, team_id) do
      :persistent_term.put(@cache_key, {jwt, System.system_time(:second)})
      {:ok, jwt}
    end
  end

  defp read_key(path) do
    case File.read(path) do
      {:ok, pem} ->
        {:ok, pem}

      {:error, reason} ->
        # The PATH is safe to log and is the whole diagnosis when a mount is missing. The CONTENTS
        # never are.
        Logger.error("apns: cannot read the provider key at #{path}: #{inspect(reason)}")
        {:error, :apns_key_unreadable}
    end
  end

  # Read at RUNTIME, never config.exs-baked — the same rule every other credential here follows, and
  # the one that made the Kafka producer adapter unchangeable by environment until it was fixed.
  defp config do
    key_path = env("APNS_KEY_PATH")
    key_id = env("APNS_KEY_ID")
    team_id = env("APNS_TEAM_ID")

    if key_path && key_id && team_id do
      {:ok, key_path, key_id, team_id}
    else
      {:error, :apns_not_configured}
    end
  end

  # JWS WANTS RAW R||S, OTP GIVES DER. `:crypto.sign/4` returns SEQUENCE { INTEGER r, INTEGER s },
  # 70-72 bytes depending on whether either integer needed a leading zero to stay positive. RFC 7518
  # wants each padded to exactly the curve size — 32 bytes for P-256 — and concatenated. Handing
  # APNs the DER form fails as InvalidProviderToken, which says nothing about the encoding.
  defp raw_signature(der) do
    <<0x30, _length, 0x02, r_length, rest::binary>> = der

    # r_length is bound in the match ABOVE so it must be pinned; s_length is bound in THIS pattern,
    # where a size variable is used directly.
    <<r::binary-size(^r_length), 0x02, s_length, s::binary-size(s_length)>> = rest

    pad(r) <> pad(s)
  end

  # Strip the leading zero DER adds to keep an integer positive, then left-pad to the curve size.
  defp pad(<<0, rest::binary>>) when byte_size(rest) == 32, do: rest
  defp pad(value) when byte_size(value) == 32, do: value

  defp pad(value) when byte_size(value) < 32,
    do: String.duplicate(<<0>>, 32 - byte_size(value)) <> value

  defp base64url(value), do: Base.url_encode64(value, padding: false)

  defp env(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
