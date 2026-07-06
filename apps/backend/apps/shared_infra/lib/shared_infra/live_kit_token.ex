defmodule SharedInfra.LiveKitToken do
  @moduledoc """
  Mints LiveKit access tokens — a standard **HS256 JWT** with LiveKit's documented claims (a `video`
  grant). No LiveKit SDK and no JWT library: LiveKit access tokens are plain HS256 JWTs, so we sign them
  with `:crypto.mac(:hmac, :sha256, …)` + `Jason` (both already in-tree).

  The app's own session token (`AuthService.Tokens`) is a custom `term_to_binary` format — deliberately
  NOT reused here; a LiveKit token must be a real JWT signed with the **LiveKit API secret** (separate
  from the app `TOKEN_SECRET`).

  Key/secret/URL are read from runtime config (`config :shared_infra, :livekit`, set in runtime.exs from
  `LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET` / `LIVEKIT_URL`) — never baked at compile time.
  """

  # Short-lived: the token only needs to survive the join handshake; the media session outlives it.
  @default_ttl_seconds 600

  @doc "LiveKit server URL (wss://…) returned to the client alongside the token."
  def url, do: config()[:url]

  @doc "True when an API key + secret are configured (so the `calls` feature is usable)."
  def configured? do
    cfg = config()
    present?(cfg[:api_key]) and present?(cfg[:api_secret])
  end

  @doc """
  Build a signed LiveKit access token for `identity` to join `room`.

  Options:
    * `:name` — participant display name (default: `identity`)
    * `:ttl_seconds` — token lifetime (default #{@default_ttl_seconds})
    * `:can_publish` / `:can_subscribe` — grant flags (default true)
    * `:now` — unix seconds override (tests)

  Returns `{:ok, jwt}` or `{:error, :livekit_not_configured}`.
  """
  def create(identity, room, opts \\ []) when is_binary(identity) and is_binary(room) do
    cfg = config()
    key = cfg[:api_key]
    secret = cfg[:api_secret]

    if present?(key) and present?(secret) do
      now = Keyword.get(opts, :now, System.system_time(:second))
      ttl = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)

      claims = %{
        "iss" => key,
        # LiveKit reads the participant identity from `sub`.
        "sub" => identity,
        "name" => Keyword.get(opts, :name, identity),
        "iat" => now,
        "nbf" => now,
        "exp" => now + ttl,
        "video" => %{
          "room" => room,
          "roomJoin" => true,
          "canPublish" => Keyword.get(opts, :can_publish, true),
          "canSubscribe" => Keyword.get(opts, :can_subscribe, true)
        }
      }

      {:ok, sign(claims, secret)}
    else
      {:error, :livekit_not_configured}
    end
  end

  # Standard compact JWS: base64url(header) . base64url(payload) . base64url(HMAC-SHA256), no padding.
  defp sign(claims, secret) do
    header = %{"alg" => "HS256", "typ" => "JWT"}
    signing_input = encode_segment(header) <> "." <> encode_segment(claims)

    signature =
      :crypto.mac(:hmac, :sha256, secret, signing_input) |> Base.url_encode64(padding: false)

    signing_input <> "." <> signature
  end

  defp encode_segment(map), do: map |> Jason.encode!() |> Base.url_encode64(padding: false)

  defp present?(value), do: is_binary(value) and value != ""

  defp config, do: Application.get_env(:shared_infra, :livekit, [])
end
