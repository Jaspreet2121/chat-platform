defmodule ApiGatewayWeb.V1.AuthController do
  @moduledoc """
  `POST /v1/auth/token` — end-user token-exchange. Authenticated by V1Auth; REQUIRES the SECRET-KEY
  actor (an end-user JWT may not mint more tokens → no privilege escalation). Resolves-or-creates the
  external end-user within the key's app_id and returns a short-lived end-user JWT for that {app, user}.
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
             "display_name" => Map.get(params, "display_name"),
             # Propagate the caller's mode (from the presenting key) so the minted token is same-mode.
             "mode" => Atom.to_string(conn.assigns[:v1_app_mode] || :live)
           }) do
      json(conn, result)
    else
      {:error, :forbidden} ->
        ErrorResponse.forbidden(conn, "v1.app_only", "Only an API key may mint end-user tokens")

      _ ->
        ErrorResponse.invalid_request(conn, "v1.invalid_request")
    end
  end

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
