defmodule AuthService.AppAuth do
  @moduledoc """
  End-user (integrator) token-exchange. An integrator's SERVER (authenticated by a secret API key, in
  the gateway) calls this to mint a SHORT-LIVED JWT for one of THEIR end-users, scoped to {app, user}.

  Reuses `AuthService.Tokens` for signing/verifying — the SAME crypto as session tokens, so verification
  is unified. End-user tokens carry `typ:"app_user"` (vs. a session's `typ:"access"`): the two classes
  can't be confused or escalated — `Sessions.valid_access_claims?` rejects `app_user`, and
  `verify_app_user_token/1` rejects anything that isn't `app_user`.
  """

  alias AuthService.Accounts
  alias AuthService.Tokens

  # Short TTL — these are handed to an integrator's browser; they should be refreshed via the server.
  @app_user_ttl_seconds 3600

  @doc "Resolve-or-create the external end-user within app_id, then mint a short-lived end-user JWT."
  def mint_app_user_token(attrs) do
    with {:ok, app_id} <- fetch(attrs, "app_id"),
         {:ok, external_id} <- fetch(attrs, "external_id"),
         {:ok, %{user_id: user_id}} <-
           Accounts.resolve_or_create_external_user(app_id, external_id) do
      # Carry the caller's mode so a token minted from a TEST key is observably test-mode. Isolation is
      # still purely by app_id (a test key's app_id is its twin) — mode is informational.
      mode = app_mode(attrs)
      now = DateTime.utc_now()
      expires_at = DateTime.add(now, @app_user_ttl_seconds, :second)

      claims = %{
        "typ" => "app_user",
        "app" => app_id,
        "mode" => mode,
        "sub" => user_id,
        "iat" => DateTime.to_unix(now),
        "exp" => DateTime.to_unix(expires_at),
        "iss" => Tokens.token_issuer(),
        "aud" => Tokens.token_audience()
      }

      {:ok, token} = Tokens.sign_claims(claims)

      {:ok,
       %{
         token: token,
         token_type: "app_user",
         app_id: app_id,
         mode: mode,
         user_id: user_id,
         expires_in_seconds: @app_user_ttl_seconds
       }}
    else
      _ -> {:error, :token_exchange_failed}
    end
  end

  defp app_mode(attrs) do
    case Map.get(attrs, "mode") do
      mode when mode in ["live", "test"] -> mode
      _ -> "live"
    end
  end

  @doc "Resolve-or-create an external end-user → {:ok, %{user_id}} (no token). Used to map participants."
  def resolve_external_user(attrs) do
    with {:ok, app_id} <- fetch(attrs, "app_id"),
         {:ok, external_id} <- fetch(attrs, "external_id") do
      Accounts.resolve_or_create_external_user(app_id, external_id)
    end
  end

  @doc """
  Reverse map an internal `user_id` back to the integrator's `external_id` within an app →
  {:ok, %{user_id, external_id}} | {:error, :not_found}. Used to keep internal user_ids OUT of /v1
  responses and to tenant-scope a call-link by its creator. Never creates.
  """
  def resolve_user_external_id(attrs) do
    with {:ok, app_id} <- fetch(attrs, "app_id"),
         {:ok, user_id} <- fetch(attrs, "user_id") do
      Accounts.external_id_for_user(app_id, user_id)
    end
  end

  @doc """
  Verify an end-user JWT → {:ok, %{app_id, user_id, mode}}. Rejects anything that isn't a valid,
  unexpired `typ:"app_user"` token (expiry + signature are enforced by `Tokens.verify_signed_token/1`).
  `mode` defaults to "live" for tokens minted before mode was carried.
  """
  def verify_app_user_token(token) when is_binary(token) and token != "" do
    case Tokens.verify_signed_token(token) do
      {:ok, %{"typ" => "app_user", "app" => app_id, "sub" => user_id} = claims}
      when is_binary(app_id) and is_binary(user_id) ->
        {:ok, %{app_id: app_id, user_id: user_id, mode: Map.get(claims, "mode", "live")}}

      _ ->
        {:error, :invalid_token}
    end
  end

  def verify_app_user_token(_token), do: {:error, :invalid_token}

  defp fetch(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_request}
    end
  end
end
