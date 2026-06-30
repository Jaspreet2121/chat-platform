defmodule AuthService.Sessions do
  @moduledoc """
  Device session boundary.

  The public boundary returns a contract placeholder by default. Database-backed
  session lookup is opt-in so normal tests and local development do not require
  PostgreSQL.
  """

  alias AuthService.Accounts
  alias AuthService.DeviceSessions
  alias AuthService.Tokens

  @type session_attrs :: map()
  @type result :: {:ok, map()} | {:error, atom()}

  @callback create_session(session_attrs()) :: result()
  @callback current_session(session_attrs()) :: result()
  @callback revoke_session(session_attrs()) :: result()

  def create_session(_attrs), do: {:error, :not_implemented}

  def current_session(attrs) when is_map(attrs) do
    if session_persistence_enabled?() do
      current_persisted_session(attrs)
    else
      {:ok, placeholder_session_response()}
    end
  end

  def revoke_session(_attrs), do: {:error, :not_implemented}

  @doc """
  Returns true when DB-backed session validation is enabled.

  Callers that must NOT accept the unverified placeholder session (e.g. realtime
  socket auth) use this to fail closed when the session layer is not genuinely
  DB-backed.
  """
  def persistence_enabled?, do: session_persistence_enabled?()

  defp current_persisted_session(attrs) do
    with {:repo, true} <- {:repo, repo_started?()},
         {:ok, access_token} <- bearer_token(attrs),
         {:ok, claims} <- Tokens.verify_signed_token(access_token),
         :ok <- valid_access_claims?(claims),
         :ok <- valid_issuer?(claims),
         :ok <- valid_audience?(claims),
         {:ok, device_session} <- active_device_session(claims),
         {:ok, user} <- active_user(claims),
         :ok <- token_matches_session?(claims, device_session) do
      {:ok, session_response(claims, device_session, user)}
    else
      {:repo, false} -> {:error, :repo_not_started}
      {:error, _reason} -> {:error, :session_invalid}
    end
  end

  defp bearer_token(attrs) do
    attrs
    |> get_attr(:authorization)
    |> case do
      "Bearer " <> token when token != "" -> {:ok, token}
      _ -> {:error, :session_invalid}
    end
  end

  defp valid_access_claims?(%{
         "typ" => "access",
         "sub" => user_id,
         "sid" => session_id,
         "did" => device_id,
         "iat" => issued_at,
         "exp" => expires_at
       })
       when is_binary(user_id) and is_binary(session_id) and is_binary(device_id) and
              is_integer(issued_at) and is_integer(expires_at) do
    :ok
  end

  defp valid_access_claims?(_claims), do: {:error, :session_invalid}

  defp valid_issuer?(%{"iss" => issuer}) do
    if issuer == Tokens.token_issuer(), do: :ok, else: {:error, :session_invalid}
  end

  defp valid_issuer?(_claims), do: :ok

  defp valid_audience?(%{"aud" => audience}) do
    if audience == Tokens.token_audience(), do: :ok, else: {:error, :session_invalid}
  end

  defp valid_audience?(_claims), do: :ok

  defp active_device_session(%{"sid" => session_id}) do
    case DeviceSessions.get_session(session_id) do
      nil -> {:error, :session_invalid}
      %{revoked_at: revoked_at} when not is_nil(revoked_at) -> {:error, :session_invalid}
      device_session -> {:ok, device_session}
    end
  rescue
    Ecto.Query.CastError -> {:error, :session_invalid}
  end

  defp active_user(%{"sub" => user_id}) do
    case Accounts.get_user(user_id) do
      nil -> {:error, :session_invalid}
      %{status: "active"} = user -> {:ok, user}
      _ -> {:error, :session_invalid}
    end
  rescue
    Ecto.Query.CastError -> {:error, :session_invalid}
  end

  defp token_matches_session?(claims, device_session) do
    if claims["sub"] == device_session.user_id and claims["did"] == device_session.device_id do
      :ok
    else
      {:error, :session_invalid}
    end
  end

  defp session_response(claims, device_session, user) do
    %{
      user_id: device_session.user_id,
      session_id: device_session.id,
      device_id: device_session.device_id,
      platform: device_session.platform,
      # Global platform-admin flag, surfaced so the gateway's RequireAdmin gate + the frontend admin UI
      # can read it straight off the session (no extra lookup).
      is_admin: user.is_admin == true,
      # The app (tenant) this session belongs to. Old tokens (minted before multi-tenancy) carry no
      # "app" claim → resolve to tenant zero, so existing sessions keep working without re-login.
      app_id: SharedInfra.Tenancy.app_id_or_default(claims["app"]),
      issued_at: unix_to_iso8601(claims["iat"]),
      expires_at: unix_to_iso8601(claims["exp"])
    }
  end

  defp placeholder_session_response do
    %{
      session_id: "sess_placeholder",
      user_id: "user_placeholder",
      device_id: "device_placeholder",
      platform: "ios",
      is_admin: false,
      app_id: SharedInfra.Tenancy.default_app_id(),
      issued_at: "2026-06-16T18:00:00Z",
      expires_at: "2026-06-16T18:15:00Z"
    }
  end

  defp session_persistence_enabled? do
    Application.get_env(:auth_service, :session_persistence, false) ||
      System.get_env("AUTH_SESSION_DB_BACKED") == "true"
  end

  defp repo_started?, do: not is_nil(Process.whereis(AuthService.Repo))

  defp unix_to_iso8601(unix_seconds) do
    unix_seconds
    |> DateTime.from_unix!()
    |> DateTime.to_iso8601()
  end

  defp get_attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end
end
