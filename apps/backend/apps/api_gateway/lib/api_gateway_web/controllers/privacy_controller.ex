defmodule ApiGatewayWeb.PrivacyController do
  @moduledoc """
  First-party privacy settings — GET/PATCH /api/v1/privacy. Session-authenticated; the settings are always
  the SESSION user's own.

      GET   /api/v1/privacy → {last_seen_visibility, profile_photo_visibility, read_receipts_enabled}
      PATCH /api/v1/privacy   sparse body (only the keys being changed) → the full updated settings

  Empty PATCH body → 400 `privacy.empty`; an invalid enum / non-boolean → 400 `privacy.invalid_value`. These
  settings are enforced server-wide: last_seen in SharedInfra.PresenceAuthz, profile_photo in the avatar-
  serving paths, read_receipts in the receipt live-tick + read_by_count.
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  @keys ["last_seen_visibility", "profile_photo_visibility", "read_receipts_enabled"]

  def show(conn, _params) do
    with {:ok, session} <- session(conn),
         {:ok, privacy} <- SharedInfra.UserClient.get_privacy(%{"user_id" => session.user_id}) do
      json(conn, present(privacy))
    else
      {:error, :session_invalid} -> unauthorized(conn)
      _ -> ErrorResponse.service_unavailable(conn, "privacy.unavailable")
    end
  end

  def update(conn, params) do
    with {:ok, session} <- session(conn),
         {:ok, privacy} <-
           params
           |> Map.take(@keys)
           |> Map.put("user_id", session.user_id)
           |> SharedInfra.UserClient.update_privacy() do
      json(conn, present(privacy))
    else
      {:error, :session_invalid} ->
        unauthorized(conn)

      {:error, :privacy_empty} ->
        ErrorResponse.invalid_request(conn, "privacy.empty")

      {:error, :privacy_invalid_value} ->
        ErrorResponse.invalid_request(conn, "privacy.invalid_value")

      {:error, :privacy_unavailable} ->
        ErrorResponse.service_unavailable(conn, "privacy.unavailable")

      _ ->
        ErrorResponse.invalid_request(conn, "privacy.invalid_request")
    end
  end

  defp present(privacy) do
    %{
      last_seen_visibility: get(privacy, :last_seen_visibility),
      profile_photo_visibility: get(privacy, :profile_photo_visibility),
      read_receipts_enabled: get(privacy, :read_receipts_enabled)
    }
  end

  # Default-arg form (NOT `||`) so `read_receipts_enabled: false` reads as false, not "missing".
  defp get(map, key), do: Map.get(map, key, Map.get(map, to_string(key)))

  defp session(conn) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}) do
      {:ok, session}
    else
      _ -> {:error, :session_invalid}
    end
  end

  defp authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, "Bearer " <> token}
      _ -> {:error, :session_invalid}
    end
  end

  defp unauthorized(conn),
    do: ErrorResponse.unauthorized(conn, "auth.session_invalid", "Invalid or missing session")
end
