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
             "avatar_url" => nil,
             "bio" => "User profile placeholder",
             "settings" => %{
               "locale" => "en",
               "timezone" => "UTC"
             },
             "privacy" => %{
               "last_seen_visibility" => "contacts",
               "profile_photo_visibility" => "contacts",
               "read_receipts_enabled" => true,
               # 084: "who can find me by phone", default TRUE (preserves today's discovery).
               "discoverable_by_phone" => true
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
             "avatar_url" => nil,
             "bio" => "Building chat-platform",
             "updated_at" => "2026-06-16T18:30:00Z"
           }
  end

  test "PATCH /api/v1/users/me rejects invalid update payload" do
    # "email" USED to be the unsupported field here — it is now a real profile field (091), so the
    # allow-list rule is pinned with a field that genuinely isn't one. `role` is deliberate: it is a
    # column on users_auth that a client must never be able to set through the profile patch.
    conn =
      json_request(:patch, "/api/v1/users/me", %{
        "role" => "admin"
      })

    assert conn.status == 400
    assert_invalid_error(conn, "user.invalid_request")
  end

  test "PATCH /api/v1/users/me rejects empty update payload" do
    conn = json_request(:patch, "/api/v1/users/me", %{})

    assert conn.status == 400
    assert_invalid_error(conn, "user.invalid_request")
  end

  test "GET /api/v1/users/:user_id/profile returns public profile placeholder (now session-gated)" do
    conn =
      :get
      |> conn("/api/v1/users/user_123/profile")
      # Authenticated now — /profile is no longer public (placeholder session in this mode).
      |> put_req_header("authorization", "Bearer access_token_placeholder")
      |> ApiGatewayWeb.Endpoint.call([])

    assert conn.status == 200

    # The raw avatar_media_id is DELIBERATELY ABSENT: ProfilePresenter drops it for a viewer the
    # photo-visibility rule does not clear (fail-closed default; the placeholder caller is a stranger
    # to user_123), so a client can never resolve the object itself. avatar_url: nil is the same shape
    # an avatarless profile returns — hidden and absent are indistinguishable on the wire, on purpose.
    assert Jason.decode!(conn.resp_body) == %{
             "user_id" => "user_123",
             "display_name" => "Placeholder User",
             "avatar_url" => nil,
             "bio" => "Public profile placeholder"
           }
  end

  test "GET /api/v1/users/:user_id/profile WITHOUT a session → 401 (the closed hole)" do
    conn =
      :get
      |> conn("/api/v1/users/user_123/profile")
      |> ApiGatewayWeb.Endpoint.call([])

    assert conn.status == 401
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
