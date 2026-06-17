defmodule ApiGatewayWeb.UserControllerTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  test "GET /api/v1/users/me returns current user placeholder profile" do
    conn =
      :get
      |> conn("/api/v1/users/me")
      |> put_req_header("authorization", "Bearer access_token_placeholder")
      |> ApiGatewayWeb.Endpoint.call([])

    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "user_id" => "user_placeholder",
             "display_name" => "Placeholder User",
             "avatar_media_id" => nil,
             "bio" => "User profile placeholder",
             "settings" => %{
               "locale" => "en",
               "timezone" => "UTC"
             },
             "privacy" => %{
               "last_seen_visibility" => "contacts",
               "profile_photo_visibility" => "contacts",
               "read_receipts_enabled" => true
             }
           }
  end

  test "PATCH /api/v1/users/me returns updated profile placeholder" do
    conn =
      json_request(:patch, "/api/v1/users/me", %{
        "display_name" => "Jaspreet",
        "bio" => "Building chat-platform",
        "avatar_media_id" => "media_placeholder"
      })

    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "user_id" => "user_placeholder",
             "display_name" => "Jaspreet",
             "avatar_media_id" => "media_placeholder",
             "bio" => "Building chat-platform",
             "updated_at" => "2026-06-16T18:30:00Z"
           }
  end

  test "PATCH /api/v1/users/me rejects invalid update payload" do
    conn =
      json_request(:patch, "/api/v1/users/me", %{
        "email" => "not-supported@example.com"
      })

    assert conn.status == 400
    assert_invalid_error(conn, "user.invalid_request")
  end

  test "PATCH /api/v1/users/me rejects empty update payload" do
    conn = json_request(:patch, "/api/v1/users/me", %{})

    assert conn.status == 400
    assert_invalid_error(conn, "user.invalid_request")
  end

  test "GET /api/v1/users/:user_id/profile returns public profile placeholder" do
    conn =
      :get
      |> conn("/api/v1/users/user_123/profile")
      |> ApiGatewayWeb.Endpoint.call([])

    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "user_id" => "user_123",
             "display_name" => "Placeholder User",
             "avatar_media_id" => nil,
             "bio" => "Public profile placeholder"
           }
  end

  defp json_request(method, path, params) do
    method
    |> conn(path, Jason.encode!(params))
    |> put_req_header("content-type", "application/json")
    |> ApiGatewayWeb.Endpoint.call([])
  end

  defp assert_invalid_error(conn, code) do
    assert Jason.decode!(conn.resp_body) == %{
             "error" => %{
               "code" => code,
               "message" => "Request body is invalid",
               "correlation_id" => "corr_placeholder"
             }
           }
  end
end
