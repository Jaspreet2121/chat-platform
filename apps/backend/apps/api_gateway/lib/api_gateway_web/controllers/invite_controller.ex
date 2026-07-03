defmodule ApiGatewayWeb.InviteController do
  @moduledoc """
  WhatsApp-style invites. `POST /api/v1/invites {phone_number}` (session-authed) mints/reuses an invite
  code for (caller, phone) and returns `{invite_code}`. The FRONTEND builds the link
  (`<origin>/invite/<code>`) and the pre-filled wa.me / sms: message — nothing is sent server-side
  (device URL schemes; the user's own WhatsApp/SMS app does the sending).
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  def create(conn, %{"phone_number" => phone}) when is_binary(phone) and phone != "" do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, invite} <-
           SharedInfra.AuthClient.create_invite(%{
             "inviter_user_id" => session.user_id,
             "invited_phone" => phone
           }) do
      json(conn, %{
        invite_code: Map.get(invite, :invite_code) || Map.get(invite, "invite_code"),
        invited_phone: phone
      })
    else
      {:error, :session_invalid} ->
        ErrorResponse.unauthorized(conn, "auth.session_invalid", "Session token is invalid")

      {:error, :auth_unavailable} ->
        ErrorResponse.service_unavailable(conn, "invite.unavailable")

      _ ->
        ErrorResponse.invalid_request(conn, "invite.invalid_request")
    end
  end

  def create(conn, _params), do: ErrorResponse.invalid_request(conn, "invite.invalid_request")

  defp authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, "Bearer " <> token}
      _ -> {:error, :session_invalid}
    end
  end
end
