defmodule ApiGatewayWeb.DeviceController do
  @moduledoc """
  Linked devices — WhatsApp's "Linked devices" screen. Session-authed, first-party.

    GET    /api/v1/devices               → {devices: [{device_id, device_name, platform, last_seen_at,
                                            created_at, current}]} — non-revoked, most-recently-seen first
    DELETE /api/v1/devices/:device_id    → {revoked: true} — signs that device out (device_session marked;
                                            its refresh tokens revoked; its FCM tokens deleted)
    POST   /api/v1/devices/revoke-others → {revoked_count} — "sign out everywhere else"

  `current` is derived by comparing each row against the SESSION's device_id. Revoking the CURRENT device
  is forbidden (400 devices.cannot_revoke_current) — "sign out this device" already exists as
  /auth/logout, and one gesture should not have two names. A foreign or unknown device_id → 404 (the
  lookup is caller-scoped, so another user's device simply doesn't exist here).

  Revocation is IMMEDIATE for REST (session validation checks the device_session row); an already-open
  realtime socket persists until disconnect — see AuthService.Devices for the per-client shape of that
  window and the named follow-up.
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  def index(conn, _params) do
    with {:ok, session} <- current_session(conn),
         {:ok, result} <- SharedInfra.AuthClient.list_devices(%{"user_id" => session.user_id}) do
      devices =
        result
        |> cget(:devices)
        |> List.wrap()
        |> Enum.map(fn device ->
          %{
            device_id: cget(device, :device_id),
            device_name: cget(device, :device_name),
            platform: cget(device, :platform),
            # 099: the approving phone's device_id for a QR-linked session; null for a primary login.
            linked_by: cget(device, :linked_by),
            last_seen_at: cget(device, :last_seen_at),
            created_at: cget(device, :created_at),
            current: cget(device, :device_id) == session.device_id
          }
        end)

      json(conn, %{devices: devices})
    else
      error -> handle_error(conn, error)
    end
  end

  def delete(conn, %{"device_id" => device_id}) when is_binary(device_id) and device_id != "" do
    with {:ok, session} <- current_session(conn),
         :ok <- ensure_not_current(session, device_id),
         {:ok, _result} <-
           SharedInfra.AuthClient.revoke_device(%{
             "user_id" => session.user_id,
             "device_id" => device_id,
             # 099: the caller's own device identity — a LINKED session may never revoke a PRIMARY.
             "caller_device_id" => session.device_id
           }) do
      # 099: tell the revoked device it was signed out BEFORE severing its socket, so an open web
      # tab can render "logged out on your phone" instead of a silent dead socket.
      ApiGatewayWeb.Endpoint.broadcast("user:" <> session.user_id, "session_revoked", %{
        device_id: device_id
      })

      # REALTIME SESSION REVOCATION: sever exactly that device's live socket (the per-(user, device)
      # socket id) — the same user's OTHER devices, including this caller, are untouched.
      disconnect_device_socket(session.user_id, device_id)
      json(conn, %{revoked: true})
    else
      error -> handle_error(conn, error)
    end
  end

  def delete(conn, _params), do: ErrorResponse.invalid_request(conn, "devices.invalid_request")

  def revoke_others(conn, _params) do
    with {:ok, session} <- current_session(conn),
         {:ok, result} <-
           SharedInfra.AuthClient.revoke_other_devices(%{
             "user_id" => session.user_id,
             "device_id" => session.device_id
           }) do
      # Sever each swept device's live socket; the CURRENT device's socket is untouched by construction
      # (its id was excluded from the sweep).
      result
      |> cget(:revoked_device_ids)
      |> List.wrap()
      |> Enum.each(&disconnect_device_socket(session.user_id, &1))

      json(conn, %{revoked_count: cget(result, :revoked_count) || 0})
    else
      error -> handle_error(conn, error)
    end
  end

  defp disconnect_device_socket(user_id, device_id)
       when is_binary(device_id) and device_id != "" do
    ApiGatewayWeb.Endpoint.broadcast("user_socket:#{user_id}:#{device_id}", "disconnect", %{})
  end

  defp disconnect_device_socket(_user_id, _device_id), do: :ok

  # Logout owns "sign out this device" — aliasing it here would be one gesture with two names, and a
  # client iterating a device list must not be able to cut its own session off mid-flight by accident.
  defp ensure_not_current(session, device_id) do
    if session.device_id == device_id, do: {:error, :cannot_revoke_current}, else: :ok
  end

  defp current_session(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" ->
        SharedInfra.AuthClient.current_session(%{"authorization" => "Bearer " <> token})

      _ ->
        {:error, :session_invalid}
    end
  end

  defp handle_error(conn, {:error, :session_invalid}),
    do: ErrorResponse.unauthorized(conn, "auth.session_invalid", "Invalid or missing session")

  defp handle_error(conn, {:error, :cannot_revoke_current}),
    do:
      ErrorResponse.invalid_request_with(
        conn,
        "devices.cannot_revoke_current",
        "Use logout to sign out this device",
        %{}
      )

  # 099: a QR-LINKED session tried to revoke a PRIMARY (direct-login) session — never allowed; a
  # stolen browser session must not be able to sign the phone out.
  defp handle_error(conn, {:error, :cannot_revoke_primary}),
    do:
      ErrorResponse.forbidden(
        conn,
        "devices.cannot_revoke_primary",
        "A linked device cannot sign out a primary device"
      )

  defp handle_error(conn, {:error, :device_not_found}),
    do: ErrorResponse.not_found(conn, "devices.not_found", "Device not found")

  defp handle_error(conn, {:error, :auth_unavailable}),
    do: ErrorResponse.service_unavailable(conn, "devices.unavailable")

  defp handle_error(conn, _other),
    do: ErrorResponse.invalid_request(conn, "devices.invalid_request")

  # Presence-based dual-key read (SharedInfra.Attrs): `current` compares device_id and the row carries
  # nullable fields — the `||` idiom is exactly the footgun Attrs exists for.
  defp cget(map, key) when is_map(map), do: SharedInfra.Attrs.get(map, key)
  defp cget(_map, _key), do: nil
end
