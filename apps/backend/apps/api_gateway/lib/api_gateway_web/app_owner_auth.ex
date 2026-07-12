defmodule ApiGatewayWeb.AppOwnerAuth do
  @moduledoc """
  The SINGLE app-owner authorization rule for the owner console (`/api/v1/apps`, `/api-keys`,
  `/webhooks/endpoints`, `/webhooks/deliveries`, `/usage`).

  Resolves WHICH app the caller is acting as, and proves they OWN it:

    * no `app_id` param      → the session's own app_id (tenant zero for a plain first-party user).
    * `app_id` = the default → allowed (backward-compat: first-party users with no registered app).
    * any other `app_id`     → must be in `app_owners` for this user (`AuthClient.owns_app`), else
                               `{:error, :not_owner}` → the caller's controller renders 403.

  A caller can NEVER act as an app they don't own. Extracted so this rule lives in exactly ONE place —
  ApiKeyController and WebhookEndpointController now delegate here rather than each carrying a copy. Two
  copies of an ownership rule is how tenant holes happen.

  This resolves the SCOPE only. Every query downstream must still be `WHERE app_id = <resolved>` — that
  predicate, not this gate, is what actually keeps one app's rows out of another's response.
  """

  import Plug.Conn, only: [get_req_header: 2]

  @doc "Resolve the caller's session AND the owned app they're acting as, in one step."
  @spec resolve_owned_app(Plug.Conn.t(), map()) ::
          {:ok, map(), String.t()} | {:error, atom()}
  def resolve_owned_app(conn, params) do
    with {:ok, session} <- app_session(conn),
         {:ok, app_id} <- resolve_target_app(session, params) do
      {:ok, session, app_id}
    end
  end

  @doc "The ownership rule itself, for a session the caller already resolved."
  @spec resolve_target_app(map(), map()) :: {:ok, String.t()} | {:error, :not_owner}
  def resolve_target_app(session, params) do
    case presence(Map.get(params, "app_id")) do
      nil ->
        {:ok, session.app_id}

      requested ->
        if requested == SharedInfra.Tenancy.default_app_id() do
          {:ok, requested}
        else
          case SharedInfra.AuthClient.owns_app(%{
                 "owner_user_id" => session.user_id,
                 "app_id" => requested
               }) do
            {:ok, _} -> {:ok, requested}
            _ -> {:error, :not_owner}
          end
        end
    end
  end

  @doc "The logged-in first-party session behind an owner-console request."
  def app_session(conn) do
    with {:ok, authorization} <- authorization_header(conn) do
      SharedInfra.AuthClient.current_session(%{"authorization" => authorization})
    end
  end

  defp authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token = authorization] when token != "" -> {:ok, authorization}
      _ -> {:error, :session_invalid}
    end
  end

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_), do: nil
end
