defmodule SharedInfra.AvatarToken do
  @moduledoc """
  A narrow, single-purpose capability token for the ONE unauthenticated avatar path — web-push
  notification icons (`GET /api/v1/push/avatar/:token`). It is minted by the notification sender and
  verified by the gateway; it is the ONLY way to fetch an avatar image without a session.

  WHAT IT SIGNS: `(user_id, app_id, kind: "avatar")` with an embedded, signed expiry. A token minted for
  one user or one tenant does not work for another (both are inside the signed payload and checked on
  verify), and it can never presign anything but that user's avatar in that app — the only route that
  accepts it (`/push/avatar/:token`) presigns exclusively `purpose = "user_avatar"` for the signed
  `(user_id, app_id)`. No general media route accepts this token. The `kind` claim is a second belt: a
  token whose `kind != "avatar"` fails verification.

  TRADE-OFF (deliberate, long TTL): a web-push notification is often opened hours after it arrives, so a
  short-TTL presigned URL cannot be embedded in it. This token therefore has a LONG TTL (7 days). The
  cost is bounded: a LEAKED token grants read of exactly ONE user's avatar IMAGE, in ONE app, until it
  expires — nothing else (no profile data, no other media, no other user).

  ROTATION: signed with `SECRET_KEY_BASE` — the shared server secret present for every service (the
  compose `*secrets` anchor), read at RUNTIME. Rotating `SECRET_KEY_BASE` immediately invalidates every
  outstanding avatar token (along with other Phoenix-signed data). There is no per-token revocation;
  rotation is the kill switch.

  Verification is timing-safe and checks BOTH signature and expiry (`Plug.Crypto.verify/4` uses
  `Plug.Crypto.secure_compare/2` internally and enforces `max_age`). An expired or tampered token is
  indistinguishable to the caller — the route returns 404, never revealing whether the user/avatar exists.
  """

  @salt "avatar-icon-capability-v1"
  @max_age_seconds 7 * 24 * 60 * 60
  @kind "avatar"

  @doc "Mint a token bound to `(user_id, app_id, kind: avatar)`."
  @spec sign(String.t(), String.t()) :: String.t()
  def sign(user_id, app_id) when is_binary(user_id) and is_binary(app_id) do
    Plug.Crypto.sign(secret(), @salt, %{"u" => user_id, "a" => app_id, "k" => @kind})
  end

  @doc """
  Verify signature + expiry (timing-safe) and enforce the `avatar` kind. Returns the bound
  `%{user_id, app_id}` or `:error` for a tampered / expired / wrong-kind / malformed token.
  """
  @spec verify(term()) :: {:ok, %{user_id: String.t(), app_id: String.t()}} | :error
  def verify(token) when is_binary(token) and token != "" do
    case Plug.Crypto.verify(secret(), @salt, token, max_age: @max_age_seconds) do
      {:ok, %{"u" => user_id, "a" => app_id, "k" => @kind}}
      when is_binary(user_id) and is_binary(app_id) ->
        {:ok, %{user_id: user_id, app_id: app_id}}

      _ ->
        :error
    end
  end

  def verify(_token), do: :error

  # SECRET_KEY_BASE (the shared server secret, present for every service). A fixed dev/test fallback keeps
  # `mix test` deterministic; it is NEVER the value used in production (prod fails fast on a placeholder
  # SECRET_KEY_BASE via SharedInfra.ProdConfig).
  defp secret do
    case System.get_env("SECRET_KEY_BASE") do
      value when is_binary(value) and value != "" -> value
      _ -> "dev_only_avatar_token_secret_base_change_me_not_for_production_use_at_all"
    end
  end
end
