defmodule ApiGatewayWeb.Plugs.V1Auth do
  @moduledoc """
  Authenticates a public `/v1` request and assigns its tenant scope. Accepts EITHER:
    * a secret API key (`Authorization: Bearer sk_…`) — the integrator's SERVER, or
    * an end-user JWT (`Authorization: Bearer <jwt>`) — the integrator's client.
  Both resolve to an app_id. Assigns `:v1_app_id`, `:v1_actor` (:app | :end_user), and `:v1_user_id`
  (the end-user, when applicable).

  Every failure mode — missing/malformed header, unknown OR revoked key, expired/tampered JWT — returns
  the SAME 401 with the SAME body. Nothing distinguishes prefix-vs-full, exists-vs-revoked, or
  key-vs-jwt: no oracle. Secret-key verification is a sha256 hash lookup (no early-exit secret compare).
  """

  import Plug.Conn

  alias ApiGatewayWeb.ErrorResponse

  def init(opts), do: opts

  def call(conn, _opts) do
    case bearer(conn) do
      {:ok, "sk_" <> _ = secret_key} ->
        case SharedInfra.AuthClient.verify_api_key(%{"api_key" => secret_key}) do
          {:ok, %{app_id: app_id}} -> assign_scope(conn, app_id, :app, nil)
          _ -> unauthorized(conn)
        end

      {:ok, jwt} ->
        case SharedInfra.AuthClient.verify_app_user_token(%{"token" => jwt}) do
          {:ok, %{app_id: app_id, user_id: user_id}} ->
            assign_scope(conn, app_id, :end_user, user_id)

          _ ->
            unauthorized(conn)
        end

      :error ->
        unauthorized(conn)
    end
  end

  defp assign_scope(conn, app_id, actor, user_id) do
    conn
    |> assign(:v1_app_id, app_id)
    |> assign(:v1_actor, actor)
    |> assign(:v1_user_id, user_id)
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      _ -> :error
    end
  end

  defp unauthorized(conn) do
    conn
    |> ErrorResponse.unauthorized("v1.unauthorized", "Invalid or missing credentials")
    |> halt()
  end
end
