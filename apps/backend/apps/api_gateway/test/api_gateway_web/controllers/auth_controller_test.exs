defmodule ApiGatewayWeb.AuthControllerTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  test "POST /api/v1/auth/otp/request returns placeholder OTP request response" do
    conn =
      json_request(
        :post,
        "/api/v1/auth/otp/request",
        %{
          "phone_number" => "+919999999999",
          "purpose" => "login"
        }
      )

    assert conn.status == 202

    assert Jason.decode!(conn.resp_body) == %{
             "otp_request_id" => "otp_req_placeholder",
             "delivery_method" => "sms",
             "expires_in_seconds" => 300,
             "retry_after_seconds" => 60
           }
  end

  test "POST /api/v1/auth/otp/verify returns placeholder token response" do
    conn =
      json_request(
        :post,
        "/api/v1/auth/otp/verify",
        %{
          "otp_request_id" => "11111111-1111-1111-1111-111111111111",
          "phone_number" => "+919999999999",
          "otp" => "123456",
          "device_id" => "dev_123",
          "platform" => "ios"
        }
      )

    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "user_id" => "user_placeholder",
             "session_id" => "sess_placeholder",
             "access_token" => "access_token_placeholder",
             "access_token_expires_in_seconds" => 900,
             "refresh_token" => "refresh_token_placeholder",
             "refresh_token_expires_in_seconds" => 2_592_000
           }
  end

  test "POST /api/v1/auth/refresh returns placeholder refreshed tokens" do
    conn =
      json_request(
        :post,
        "/api/v1/auth/refresh",
        %{
          "refresh_token" => "placeholder_refresh_token"
        }
      )

    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "access_token" => "new_access_token_placeholder",
             "access_token_expires_in_seconds" => 900,
             "refresh_token" => "new_refresh_token_placeholder",
             "refresh_token_expires_in_seconds" => 2_592_000
           }
  end

  test "POST /api/v1/auth/logout returns no content" do
    conn =
      json_request(
        :post,
        "/api/v1/auth/logout",
        %{
          "refresh_token" => "placeholder_refresh_token"
        }
      )

    assert conn.status == 204
    assert conn.resp_body == ""
  end

  test "GET /api/v1/auth/session returns placeholder session response" do
    conn =
      :get
      |> conn("/api/v1/auth/session")
      |> put_req_header("authorization", "Bearer access_token_placeholder")
      |> ApiGatewayWeb.Endpoint.call([])

    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "session_id" => "sess_placeholder",
             "user_id" => "user_placeholder",
             "device_id" => "device_placeholder",
             "platform" => "ios",
             "is_admin" => false,
             "app_id" => "00000000-0000-0000-0000-000000000001",
             "issued_at" => "2026-06-16T18:00:00Z",
             "expires_at" => "2026-06-16T18:15:00Z"
           }
  end

  test "POST /api/v1/auth/otp/request validates required fields" do
    conn = json_request(:post, "/api/v1/auth/otp/request", %{})

    assert conn.status == 400
    assert_invalid_error(conn, "auth.invalid_request")
  end

  test "POST /api/v1/auth/otp/verify validates one OTP field is present" do
    conn =
      json_request(
        :post,
        "/api/v1/auth/otp/verify",
        %{
          "otp_request_id" => "11111111-1111-1111-1111-111111111111",
          "phone_number" => "+919999999999",
          "device_id" => "dev_123",
          "platform" => "ios"
        }
      )

    assert conn.status == 400
    assert_invalid_error(conn, "auth.invalid_request")
  end

  test "POST /api/v1/auth/refresh validates refresh token is present" do
    conn = json_request(:post, "/api/v1/auth/refresh", %{})

    assert conn.status == 400
    assert_invalid_error(conn, "auth.invalid_request")
  end

  test "POST /api/v1/auth/logout validates refresh token is present" do
    conn = json_request(:post, "/api/v1/auth/logout", %{})

    assert conn.status == 400
    assert_invalid_error(conn, "auth.invalid_request")
  end

  defp json_request(method, path, params) do
    method
    |> conn(path, Jason.encode!(params))
    |> put_req_header("content-type", "application/json")
    |> ApiGatewayWeb.Endpoint.call([])
  end

  defp assert_invalid_error(conn, code) do
    assert %{
             "error" => %{
               "code" => ^code,
               "message" => "Request body is invalid",
               "correlation_id" => correlation_id
             }
           } = Jason.decode!(conn.resp_body)

    assert is_binary(correlation_id) and correlation_id != "" and
             correlation_id != "corr_placeholder"
  end
end
