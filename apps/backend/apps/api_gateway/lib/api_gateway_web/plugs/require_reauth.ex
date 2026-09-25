defmodule ApiGatewayWeb.Plugs.RequireReauth do
  @moduledoc """
  STEP-UP GATE for the irreversible admin actions (132): ban, permanent delete, and a role change
  touching root/admin.

  A console session is opened with an ordinary login and may have been unattended for hours; these
  three are one API call from destroying something. The caller must present a proof — minted by
  `POST /api/v1/admin/reauth/verify` after re-entering an OTP sent to their OWN registered number —
  that is less than five minutes old AND belongs to them.

  The proof rides the `x-admin-reauth` header, with a `reauth_token` body field accepted as a
  fallback for clients that find headers awkward. Every failure answers the same
  403 `admin.reauth_required`: missing, malformed, expired, wrong type and somebody else's token are
  indistinguishable to the caller, so this cannot be used to probe what a token is or who holds it.

  Runs AFTER `RequireAdmin` (which resolves `conn.assigns.admin_session`) and after
  `RequirePermission` — you must be allowed to do the thing at all before being asked to prove it is
  really you.
  """

  import Plug.Conn

  alias ApiGatewayWeb.ErrorResponse

  def init(opts), do: opts

  def call(conn, _opts) do
    actor = conn.assigns[:admin_session][:user_id]

    case SharedInfra.AuthClient.admin_reauth_check(%{
           "token" => reauth_token(conn),
           "user_id" => actor || ""
         }) do
      {:ok, _} ->
        conn

      {:error, :auth_unavailable} ->
        conn |> ErrorResponse.service_unavailable("admin.unavailable") |> halt()

      _ ->
        conn
        |> ErrorResponse.forbidden(
          "admin.reauth_required",
          "Confirm it's you: re-enter the code sent to your phone"
        )
        |> halt()
    end
  end

  @doc "The presented proof: the header first, the body field as a fallback. Never a query param."
  def reauth_token(conn) do
    case get_req_header(conn, "x-admin-reauth") do
      [value | _] when is_binary(value) and value != "" -> value
      _ -> body_token(conn)
    end
  end

  defp body_token(%{body_params: %{"reauth_token" => value}})
       when is_binary(value) and value != "",
       do: value

  defp body_token(_conn), do: ""
end
