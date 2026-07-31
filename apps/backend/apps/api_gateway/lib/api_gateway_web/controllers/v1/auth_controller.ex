defmodule ApiGatewayWeb.V1.AuthController do
  @moduledoc """
  `POST /v1/auth/token` — end-user token-exchange. Authenticated by V1Auth; REQUIRES the SECRET-KEY
  actor (an end-user JWT may not mint more tokens → no privilege escalation). Resolves-or-creates the
  external end-user within the key's app_id and returns a short-lived end-user JWT for that {app, user}.
  When `display_name` is supplied, it is persisted to the end-user's profile via the SAME user-service
  boundary the first-party `/api/v1/users/me` PATCH uses (scoped to that {app, user}'s user_id).
  """

  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  def token(conn, params) do
    with :ok <- require_app_actor(conn),
         {:ok, external_id} <- fetch(params, "end_user_id"),
         {:ok, result} <-
           SharedInfra.AuthClient.mint_app_user_token(%{
             "app_id" => conn.assigns.v1_app_id,
             "external_id" => external_id,
             # Propagate the caller's mode (from the presenting key) so the minted token is same-mode.
             "mode" => Atom.to_string(conn.assigns[:v1_app_mode] || :live)
           }) do
      # Persist the display name (best-effort) for the resolved end-user. Set-on-create /
      # update-if-provided / never-wipe — a blank or absent name performs NO write. Keyed by the
      # resolved user_id (App-A's "alice" ≠ App-B's "alice" → different user_ids → no cross-app spoof).
      # A profile-write hiccup must NOT fail auth: the token is already minted and valid.
      maybe_set_display_name(get(result, :user_id), Map.get(params, "display_name"))
      json(conn, result)
    else
      {:error, :forbidden} ->
        ErrorResponse.forbidden(conn, "v1.app_only", "Only an API key may mint end-user tokens")

      _ ->
        ErrorResponse.invalid_request(conn, "v1.invalid_request")
    end
  end

  defp maybe_set_display_name(user_id, display_name)
       when is_binary(user_id) and user_id != "" and is_binary(display_name) and
              display_name != "" do
    SharedInfra.UserClient.update_current_profile(%{
      "user_id" => user_id,
      "display_name" => display_name
    })

    :ok
  end

  defp maybe_set_display_name(_user_id, _display_name), do: :ok

  defp get(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp get(_map, _key), do: nil

  defp require_app_actor(conn) do
    if conn.assigns[:v1_actor] == :app, do: :ok, else: {:error, :forbidden}
  end

  defp fetch(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_request}
    end
  end
end
