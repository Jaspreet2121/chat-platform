defmodule ApiGatewayWeb.AuthController do
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  def request_otp(conn, params) do
    with :ok <- require_fields(params, ["phone_number", "purpose"]),
         {:ok, response} <- AuthService.OTP.request_otp(params) do
      conn
      |> put_status(:accepted)
      |> json(response)
    else
      _ -> invalid_request(conn)
    end
  end

  def verify_otp(conn, params) do
    with :ok <- require_fields(params, ["otp_request_id", "phone_number", "device_id"]),
         :ok <- require_any_field(params, ["otp", "otp_code"]),
         {:ok, response} <- AuthService.OTP.verify_otp(params) do
      json(conn, response)
    else
      {:error, :otp_invalid} -> otp_invalid(conn)
      _ -> invalid_request(conn)
    end
  end

  def refresh(conn, params) do
    with :ok <- require_fields(params, ["refresh_token"]),
         {:ok, response} <- AuthService.Tokens.refresh(params) do
      json(conn, response)
    else
      {:error, :refresh_invalid} -> refresh_invalid(conn)
      _ -> invalid_request(conn)
    end
  end

  def logout(conn, params) do
    with :ok <- require_fields(params, ["refresh_token"]),
         {:ok, _response} <- AuthService.Tokens.revoke(params) do
      send_resp(conn, :no_content, "")
    else
      {:error, :refresh_invalid} -> refresh_invalid(conn)
      _ -> invalid_request(conn)
    end
  end

  def session(conn, params) do
    params = Map.put(params, "authorization", authorization_header(conn))

    with {:ok, response} <- AuthService.Sessions.current_session(params) do
      json(conn, response)
    else
      {:error, :session_invalid} -> session_invalid(conn)
    end
  end

  defp require_fields(params, fields) do
    if Enum.all?(fields, &param_present?(params, &1)) do
      :ok
    else
      {:error, :invalid_request}
    end
  end

  defp require_any_field(params, fields) do
    if Enum.any?(fields, &param_present?(params, &1)) do
      :ok
    else
      {:error, :invalid_request}
    end
  end

  defp param_present?(params, field) when is_binary(field) do
    present?(params[field]) or present?(params[String.to_existing_atom(field)])
  rescue
    ArgumentError -> present?(params[field])
  end

  defp present?(value), do: not is_nil(value) and value != ""

  defp invalid_request(conn), do: ErrorResponse.invalid_request(conn, "auth.invalid_request")

  defp otp_invalid(conn),
    do: ErrorResponse.unauthorized(conn, "auth.otp_invalid", "OTP is wrong or expired")

  defp refresh_invalid(conn),
    do: ErrorResponse.unauthorized(conn, "auth.refresh_invalid", "Refresh token is invalid")

  defp session_invalid(conn),
    do: ErrorResponse.unauthorized(conn, "auth.session_invalid", "Session token is invalid")

  defp authorization_header(conn) do
    conn
    |> get_req_header("authorization")
    |> List.first()
  end
end
