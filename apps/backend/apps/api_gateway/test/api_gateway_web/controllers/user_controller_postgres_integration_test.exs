defmodule ApiGatewayWeb.UserControllerPostgresIntegrationTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AuthService.Repo, as: AuthRepo
  alias AuthService.Schemas.DeviceSession
  alias AuthService.Schemas.UserAuth
  alias AuthService.Tokens
  alias UserService.Repo, as: UserRepo
  alias UserService.Schemas.UserProfile

  @tag :postgres_integration
  test "GET /api/v1/users/me returns authenticated user with empty profile fields when profile row is missing" do
    fixture = create_session_fixture!()
    access_token = create_access_token!(fixture)

    conn = current_user_request(access_token)

    assert conn.status == 200
    response = Jason.decode!(conn.resp_body)

    assert response["user_id"] == fixture.user_id
    assert response["display_name"] == nil
    assert response["bio"] == nil
    assert response["avatar_media_id"] == nil
    assert response["settings"]["locale"] == "en"
    assert response["privacy"]["read_receipts_enabled"] == true
  end

  @tag :postgres_integration
  test "GET /api/v1/users/:user_id/profile returns DB-backed public profile" do
    user_id = Ecto.UUID.generate()
    avatar_media_id = Ecto.UUID.generate()

    insert_user_auth_parent_for_user_repo!(user_id)

    assert {:ok, _profile} =
             %UserProfile{}
             |> UserProfile.changeset(%{
               "user_id" => user_id,
               "display_name" => "Public Jaspreet",
               "avatar_media_id" => avatar_media_id,
               "bio" => "Public profile bio"
             })
             |> UserRepo.insert()

    # The public-profile read became SESSION-GATED; this test predated the gate and sent no
    # credentials, so it had been asserting 200 against a route that answers 401.
    viewer = create_session_fixture!()
    conn = public_profile_request(user_id, create_access_token!(viewer))

    assert conn.status == 200
    response = Jason.decode!(conn.resp_body)

    assert response["user_id"] == user_id
    assert response["display_name"] == "Public Jaspreet"
    assert response["bio"] == "Public profile bio"

    # The AVATAR is viewer-dependent, so it can no longer be asserted as a constant. ProfilePresenter
    # applies the photo-visibility rule, and for a viewer who is not a contact it drops the raw
    # avatar_media_id entirely (so the client cannot resolve the object itself) and returns
    # avatar_url: nil — deliberately the same shape a genuinely avatarless profile returns. The old
    # assertion (avatar_media_id == the seeded id) described the pre-visibility-rule world.
    assert response["avatar_url"] == nil
    refute Map.has_key?(response, "avatar_media_id")
    assert is_binary(avatar_media_id)

    # Authenticating the test above must NOT quietly delete the only coverage of the gate itself:
    # the unauthenticated call still has to be refused.
    assert public_profile_request(user_id).status == 401
  end

  @tag :postgres_integration
  test "PATCH /api/v1/users/me rejects profile create when profile persistence cannot satisfy parent FK" do
    fixture = create_session_fixture!()
    access_token = create_access_token!(fixture)

    conn =
      current_user_patch_request(access_token, %{
        "display_name" => "Jaspreet",
        "bio" => "Building chat-platform"
      })

    assert conn.status == 400

    assert %{
             "error" => %{
               "code" => "user.invalid_request"
             }
           } = Jason.decode!(conn.resp_body)
  end

  @tag :postgres_integration
  test "PATCH /api/v1/users/me rejects missing Authorization header" do
    conn =
      current_user_patch_request(nil, %{
        "display_name" => "Jaspreet"
      })

    assert conn.status == 401
    assert_session_invalid(conn)
  end

  @tag :postgres_integration
  test "PATCH /api/v1/users/me rejects invalid update payload" do
    fixture = create_session_fixture!()
    access_token = create_access_token!(fixture)

    conn =
      current_user_patch_request(access_token, %{
        "email" => "not-supported@example.com"
      })

    assert conn.status == 400

    assert %{
             "error" => %{
               "code" => "user.invalid_request"
             }
           } = Jason.decode!(conn.resp_body)
  end

  @tag :postgres_integration
  test "GET /api/v1/users/me rejects missing Authorization header" do
    conn = current_user_request()

    assert conn.status == 401
    assert_session_invalid(conn)
  end

  @tag :postgres_integration
  test "GET /api/v1/users/me rejects invalid access token" do
    conn = current_user_request("not-a-signed-envelope")

    assert conn.status == 401
    assert_session_invalid(conn)
  end

  @tag :postgres_integration
  test "GET /api/v1/users/me rejects revoked device session" do
    fixture = create_session_fixture!()
    access_token = create_access_token!(fixture)

    device_session = AuthRepo.get!(DeviceSession, fixture.session_id)

    assert {:ok, _device_session} =
             AuthService.DeviceSessions.update_device_session(device_session, %{
               "revoked_at" => DateTime.utc_now()
             })

    conn = current_user_request(access_token)

    assert conn.status == 401
    assert_session_invalid(conn)
  end

  @tag :postgres_integration
  test "GET /api/v1/users/me rejects token for missing user" do
    fixture = create_session_fixture!()

    access_token =
      create_access_token!(%{
        fixture
        | user_id: Ecto.UUID.generate()
      })

    conn = current_user_request(access_token)

    assert conn.status == 401
    assert_session_invalid(conn)
  end

  setup do
    previous_auth_session_persistence =
      Application.get_env(:auth_service, :session_persistence, false)

    previous_user_profile_persistence =
      Application.get_env(:user_service, :user_profile_persistence, false)

    Application.put_env(:auth_service, :session_persistence, true)
    Application.put_env(:user_service, :user_profile_persistence, true)

    start_repo!(AuthRepo)
    start_repo!(UserRepo)

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(AuthRepo)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(UserRepo)

    on_exit(fn ->
      Application.put_env(:auth_service, :session_persistence, previous_auth_session_persistence)

      Application.put_env(
        :user_service,
        :user_profile_persistence,
        previous_user_profile_persistence
      )
    end)

    :ok
  end

  defp current_user_request(access_token \\ nil) do
    conn = conn(:get, "/api/v1/users/me")

    conn =
      if access_token do
        put_req_header(conn, "authorization", "Bearer #{access_token}")
      else
        conn
      end

    ApiGatewayWeb.Endpoint.call(conn, [])
  end

  defp public_profile_request(user_id, access_token \\ nil) do
    conn = conn(:get, "/api/v1/users/#{user_id}/profile")

    conn =
      if access_token,
        do: put_req_header(conn, "authorization", "Bearer #{access_token}"),
        else: conn

    ApiGatewayWeb.Endpoint.call(conn, [])
  end

  defp insert_user_auth_parent_for_user_repo!(user_id) do
    UserRepo.query!(
      """
      INSERT INTO users_auth (id, email, status)
      VALUES ($1, $2, 'active')
      """,
      [
        Ecto.UUID.dump!(user_id),
        "public-profile-#{System.unique_integer([:positive])}@example.test"
      ]
    )
  end

  defp current_user_patch_request(access_token, params) do
    conn =
      :patch
      |> conn("/api/v1/users/me", Jason.encode!(params))
      |> put_req_header("content-type", "application/json")

    conn =
      if access_token do
        put_req_header(conn, "authorization", "Bearer #{access_token}")
      else
        conn
      end

    ApiGatewayWeb.Endpoint.call(conn, [])
  end

  defp create_session_fixture! do
    user_id = Ecto.UUID.generate()
    session_id = Ecto.UUID.generate()
    device_id = "profile-device-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now()

    assert {:ok, user} =
             %UserAuth{}
             |> UserAuth.changeset(%{
               "id" => user_id,
               "phone_number" => unique_phone_number(),
               "status" => "active"
             })
             |> AuthRepo.insert()

    assert {:ok, device_session} =
             %DeviceSession{}
             |> DeviceSession.changeset(%{
               "id" => session_id,
               "user_id" => user.id,
               "device_id" => device_id,
               "device_name" => "Integration Device",
               "platform" => "ios",
               "refresh_token_hash" => Tokens.hash_token("profile-refresh-token-#{device_id}"),
               "last_seen_at" => now
             })
             |> AuthRepo.insert()

    %{
      user_id: user.id,
      session_id: device_session.id,
      device_id: device_session.device_id,
      platform: device_session.platform
    }
  end

  defp create_access_token!(fixture) do
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, Tokens.access_token_ttl_seconds(), :second)

    claims = %{
      "typ" => "access",
      "sub" => fixture.user_id,
      "sid" => fixture.session_id,
      "did" => fixture.device_id,
      "iat" => DateTime.to_unix(now),
      "exp" => DateTime.to_unix(expires_at),
      "jti" => Ecto.UUID.generate()
    }

    assert {:ok, token} = Tokens.sign_claims(claims)

    token
  end

  defp assert_session_invalid(conn) do
    assert %{
             "error" => %{
               "code" => "auth.session_invalid"
             }
           } = Jason.decode!(conn.resp_body)
  end

  defp start_repo!(repo) do
    case repo.start_link() do
      {:ok, pid} ->
        Process.unlink(pid)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end

  defp unique_phone_number do
    "+1555#{System.unique_integer([:positive])}"
  end
end
