defmodule ApiGatewayWeb.AdminReauthController do
  @moduledoc """
  Step-up re-auth (132): prove it is really you, then act.

  Two calls. `request` sends a one-time code to the acting admin's OWN registered number — the
  destination is read from the database, never from the body, so an admin cannot nominate where
  their own step-up code goes. `verify` exchanges the code for a five-minute proof bound to that
  admin, which `ApiGatewayWeb.Plugs.RequireReauth` then requires on ban, permanent delete, and a
  role change touching root/admin.

  Gated by `RequireAdmin` only: ANY console role may step up. What the proof unlocks is decided per
  action by the permission plugs — stepping up does not grant a capability you do not have.
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  def request(conn, _params) do
    case SharedInfra.AuthClient.admin_reauth_request(%{"user_id" => actor(conn)}) do
      {:ok, data} -> json(conn, data)
      {:error, reason} -> error(conn, reason)
    end
  end

  def verify(conn, params) do
    case SharedInfra.AuthClient.admin_reauth_verify(%{
           "user_id" => actor(conn),
           "otp_request_id" => params["otp_request_id"],
           "otp_code" => params["otp_code"]
         }) do
      {:ok, data} -> json(conn, data)
      {:error, reason} -> error(conn, reason)
    end
  end

  defp actor(conn), do: conn.assigns.admin_session.user_id

  # An admin with no phone on file cannot step up — say so plainly rather than 500ing, because the
  # fix is administrative (give them a number), not a retry.
  defp error(conn, :reauth_no_destination),
    do:
      ErrorResponse.invalid_request(
        conn,
        "admin.reauth_no_destination"
      )

  defp error(conn, :auth_unavailable),
    do: ErrorResponse.service_unavailable(conn, "admin.unavailable")

  # Every verify failure — wrong code, expired, burned, unknown request id — is one answer. A
  # distinct code per cause would turn this into an oracle for someone holding a stolen console
  # session.
  defp error(conn, _reason),
    do:
      ErrorResponse.forbidden(
        conn,
        "admin.reauth_failed",
        "That code didn't work. Request a new one."
      )
end
