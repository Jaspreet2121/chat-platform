defmodule ApiGatewayWeb.AuthControllerPostgresIntegrationTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AuthService.Repo
  alias AuthService.Accounts
  alias AuthService.Schemas.DeviceSession
  alias AuthService.Schemas.RefreshToken
  alias AuthService.Schemas.UserAuth
  alias AuthService.Schemas.VerificationCode
  alias AuthService.RefreshTokens
  alias AuthService.Tokens
  alias AuthService.VerificationCodes

  @tag :postgres_integration
  test "POST /api/v1/auth/otp/request persists a hashed verification code" do
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

    response = Jason.decode!(conn.resp_body)

    assert response["delivery_method"] == "sms"
    assert response["expires_in_seconds"] == 300
    assert response["retry_after_seconds"] == 60
    assert is_binary(response["otp_request_id"])
    refute Map.has_key?(response, "otp")
    refute Map.has_key?(response, "otp_code")

    verification_code = Repo.get!(VerificationCode, response["otp_request_id"])

    assert verification_code.destination == "+919999999999"
    assert verification_code.purpose == "login"
    assert verification_code.attempts == 0
    assert verification_code.consumed_at == nil
    assert String.starts_with?(verification_code.code_hash, "sha256:")
    assert DateTime.compare(verification_code.expires_at, DateTime.utc_now()) == :gt
  end

  @tag :postgres_integration
  test "POST /api/v1/auth/otp/verify creates user, consumes code, and stores refresh token hash" do
    phone_number = unique_phone_number()
    otp_request_id = create_verification_code!(phone_number, "123456")

    conn =
      json_request(
        :post,
        "/api/v1/auth/otp/verify",
        %{
          "otp_request_id" => otp_request_id,
          "phone_number" => phone_number,
          "otp_code" => "123456",
          "device_id" => "ios-device-verify",
          "platform" => "ios",
          "device_name" => "Integration iPhone"
        }
      )

    assert conn.status == 200
    response = Jason.decode!(conn.resp_body)

    assert {:ok, _} = Ecto.UUID.cast(response["user_id"])
    assert {:ok, _} = Ecto.UUID.cast(response["session_id"])
    assert is_binary(response["access_token"])
    assert is_binary(response["refresh_token"])
    # The LOGIN path deliberately does NOT use Tokens' global default access TTL: otp.ex passes
    # `access_ttl_seconds: Tokens.session_ttl_seconds(remember_me?)`, documented at tokens.ex ("the
    # login path passes :access_ttl_seconds (remember-me aware); other callers use the global
    # default"). This test used to assert 900 — the one value this path intentionally bypasses.
    # Assert the RELATIONSHIP, not the number, so it cannot go stale when the value moves.
    assert response["access_token_expires_in_seconds"] ==
             AuthService.Tokens.session_ttl_seconds(false)

    refute response["access_token_expires_in_seconds"] == 900

    assert response["refresh_token_expires_in_seconds"] == 2_592_000

    assert %UserAuth{id: user_id, phone_number: ^phone_number} =
             Repo.get_by(UserAuth, phone_number: phone_number)

    verification_code = Repo.get!(VerificationCode, otp_request_id)
    assert verification_code.consumed_at != nil

    refresh_token =
      Repo.get_by!(RefreshToken, user_id: user_id, device_id: "ios-device-verify")

    assert refresh_token.token_hash == Tokens.hash_token(response["refresh_token"])
    refute refresh_token.token_hash == response["refresh_token"]
    assert String.starts_with?(refresh_token.token_hash, "sha256:")

    assert %DeviceSession{id: session_id, refresh_token_hash: refresh_token_hash} =
             Repo.get_by(DeviceSession, user_id: user_id, device_id: "ios-device-verify")

    assert session_id == response["session_id"]
    assert refresh_token_hash == refresh_token.token_hash
  end

  # The other half of the same rule: remember-me selects the LONGER session TTL. Asserting the
  # relationship (remember-me > plain, and each equals its Tokens value) rather than 604800 vs 10800
  # keeps this honest when either number moves.
  #
  # A 3h access token is NOT a revocation risk here: current_session checks
  # device_sessions.revoked_at on EVERY request, so sign-out is immediate regardless of token
  # lifetime — token TTL does not gate revocation.
  @tag :postgres_integration
  test "the login access TTL IS the session TTL, and remember-me yields the longer one" do
    verify = fn remember_me ->
      phone_number = unique_phone_number()
      otp_request_id = create_verification_code!(phone_number, "123456")

      conn =
        json_request(:post, "/api/v1/auth/otp/verify", %{
          "otp_request_id" => otp_request_id,
          "phone_number" => phone_number,
          "otp_code" => "123456",
          "device_id" => "ios-remember-#{remember_me}",
          "platform" => "ios",
          "remember_me" => remember_me
        })

      assert conn.status == 200
      Jason.decode!(conn.resp_body)["access_token_expires_in_seconds"]
    end

    plain = verify.(false)
    remembered = verify.(true)

    assert plain == AuthService.Tokens.session_ttl_seconds(false)
    assert remembered == AuthService.Tokens.session_ttl_seconds(true)
    assert remembered > plain
  end

  @tag :postgres_integration
  test "POST /api/v1/auth/otp/verify reuses existing user for destination" do
    phone_number = unique_phone_number()
    existing_user = create_user!(phone_number)
    otp_request_id = create_verification_code!(phone_number, "123456")

    conn =
      json_request(
        :post,
        "/api/v1/auth/otp/verify",
        %{
          "otp_request_id" => otp_request_id,
          "phone_number" => phone_number,
          "otp" => "123456",
          "device_id" => "web-device-verify",
          "platform" => "web"
        }
      )

    assert conn.status == 200
    response = Jason.decode!(conn.resp_body)

    assert response["user_id"] == existing_user.id
    assert Repo.aggregate(UserAuth, :count, :id) == 1
  end

  @tag :postgres_integration
  test "POST /api/v1/auth/otp/verify rejects expired OTP" do
    phone_number = unique_phone_number()
    otp_request_id = create_verification_code!(phone_number, "123456", expires_in_seconds: -60)

    conn =
      json_request(
        :post,
        "/api/v1/auth/otp/verify",
        %{
          "otp_request_id" => otp_request_id,
          "phone_number" => phone_number,
          "otp_code" => "123456",
          "device_id" => "ios-device-expired",
          "platform" => "ios"
        }
      )

    assert conn.status == 401
    assert_otp_invalid(conn)
    assert Repo.get!(VerificationCode, otp_request_id).consumed_at == nil
    assert Repo.get_by(UserAuth, phone_number: phone_number) == nil
  end

  @tag :postgres_integration
  test "POST /api/v1/auth/otp/verify rejects consumed OTP" do
    phone_number = unique_phone_number()

    otp_request_id =
      create_verification_code!(phone_number, "123456", consumed_at: DateTime.utc_now())

    conn =
      json_request(
        :post,
        "/api/v1/auth/otp/verify",
        %{
          "otp_request_id" => otp_request_id,
          "phone_number" => phone_number,
          "otp_code" => "123456",
          "device_id" => "ios-device-consumed",
          "platform" => "ios"
        }
      )

    assert conn.status == 401
    assert_otp_invalid(conn)
    assert Repo.get_by(UserAuth, phone_number: phone_number) == nil
  end

  @tag :postgres_integration
  test "POST /api/v1/auth/otp/verify rejects invalid OTP" do
    phone_number = unique_phone_number()
    otp_request_id = create_verification_code!(phone_number, "123456")

    conn =
      json_request(
        :post,
        "/api/v1/auth/otp/verify",
        %{
          "otp_request_id" => otp_request_id,
          "phone_number" => phone_number,
          "otp_code" => "000000",
          "device_id" => "ios-device-invalid",
          "platform" => "ios"
        }
      )

    assert conn.status == 401
    assert_otp_invalid(conn)
    assert Repo.get!(VerificationCode, otp_request_id).consumed_at == nil
    assert Repo.get_by(UserAuth, phone_number: phone_number) == nil
  end

  @tag :postgres_integration
  test "POST /api/v1/auth/refresh rotates a valid refresh token" do
    fixture = create_refresh_fixture!("valid-refresh-token")

    conn =
      json_request(
        :post,
        "/api/v1/auth/refresh",
        %{
          "refresh_token" => "valid-refresh-token",
          "device_id" => fixture.device_id
        }
      )

    assert conn.status == 200
    response = Jason.decode!(conn.resp_body)

    assert is_binary(response["access_token"])
    assert is_binary(response["refresh_token"])
    assert response["access_token_expires_in_seconds"] == 900
    assert response["refresh_token_expires_in_seconds"] == 2_592_000
    refute response["refresh_token"] == "valid-refresh-token"

    old_token = Repo.get!(RefreshToken, fixture.refresh_token_id)
    assert old_token.revoked_at != nil
    assert old_token.replaced_by_token_id != nil

    new_token = Repo.get!(RefreshToken, old_token.replaced_by_token_id)
    assert new_token.user_id == fixture.user_id
    assert new_token.device_id == fixture.device_id
    assert new_token.token_hash == Tokens.hash_token(response["refresh_token"])
    refute new_token.token_hash == response["refresh_token"]
    assert String.starts_with?(new_token.token_hash, "sha256:")

    device_session = Repo.get!(DeviceSession, fixture.session_id)
    assert device_session.refresh_token_hash == new_token.token_hash
    assert device_session.last_seen_at != nil
  end

  @tag :postgres_integration
  test "POST /api/v1/auth/refresh rejects reuse of rotated refresh token" do
    fixture = create_refresh_fixture!("single-use-refresh-token")

    first_conn =
      json_request(
        :post,
        "/api/v1/auth/refresh",
        %{
          "refresh_token" => "single-use-refresh-token",
          "device_id" => fixture.device_id
        }
      )

    assert first_conn.status == 200

    second_conn =
      json_request(
        :post,
        "/api/v1/auth/refresh",
        %{
          "refresh_token" => "single-use-refresh-token",
          "device_id" => fixture.device_id
        }
      )

    assert second_conn.status == 401
    assert_refresh_invalid(second_conn)
  end

  @tag :postgres_integration
  test "POST /api/v1/auth/refresh rejects expired refresh token" do
    fixture = create_refresh_fixture!("expired-refresh-token", expires_in_seconds: -60)

    conn =
      json_request(
        :post,
        "/api/v1/auth/refresh",
        %{
          "refresh_token" => "expired-refresh-token",
          "device_id" => fixture.device_id
        }
      )

    assert conn.status == 401
    assert_refresh_invalid(conn)
    assert Repo.get!(RefreshToken, fixture.refresh_token_id).revoked_at == nil
  end

  @tag :postgres_integration
  test "POST /api/v1/auth/refresh rejects revoked refresh token" do
    fixture = create_refresh_fixture!("revoked-refresh-token", revoked_at: DateTime.utc_now())

    conn =
      json_request(
        :post,
        "/api/v1/auth/refresh",
        %{
          "refresh_token" => "revoked-refresh-token",
          "device_id" => fixture.device_id
        }
      )

    assert conn.status == 401
    assert_refresh_invalid(conn)
  end

  @tag :postgres_integration
  test "POST /api/v1/auth/refresh rejects revoked device session" do
    fixture = create_refresh_fixture!("revoked-session-refresh-attempt")

    assert {:ok, _device_session} =
             AuthService.DeviceSessions.update_device_session(
               Repo.get!(DeviceSession, fixture.session_id),
               %{"revoked_at" => DateTime.utc_now()}
             )

    conn =
      json_request(
        :post,
        "/api/v1/auth/refresh",
        %{
          "refresh_token" => "revoked-session-refresh-attempt",
          "device_id" => fixture.device_id
        }
      )

    assert conn.status == 401
    assert_refresh_invalid(conn)
  end

  @tag :postgres_integration
  test "POST /api/v1/auth/refresh rejects invalid refresh token" do
    fixture = create_refresh_fixture!("real-refresh-token")

    conn =
      json_request(
        :post,
        "/api/v1/auth/refresh",
        %{
          "refresh_token" => "not-the-real-token",
          "device_id" => fixture.device_id
        }
      )

    assert conn.status == 401
    assert_refresh_invalid(conn)
    assert Repo.get!(RefreshToken, fixture.refresh_token_id).revoked_at == nil
  end

  @tag :postgres_integration
  test "POST /api/v1/auth/logout revokes active refresh token and device session" do
    fixture = create_refresh_fixture!("logout-refresh-token")

    conn =
      json_request(
        :post,
        "/api/v1/auth/logout",
        %{
          "refresh_token" => "logout-refresh-token",
          "device_id" => fixture.device_id
        }
      )

    assert conn.status == 204
    assert conn.resp_body == ""

    refresh_token = Repo.get!(RefreshToken, fixture.refresh_token_id)
    assert refresh_token.revoked_at != nil

    device_session = Repo.get!(DeviceSession, fixture.session_id)
    assert device_session.revoked_at != nil
  end

  @tag :postgres_integration
  test "POST /api/v1/auth/logout invalidates current session access token" do
    fixture = create_refresh_fixture!("logout-session-refresh-token")
    access_token = create_access_token!(fixture)

    logout_conn =
      json_request(
        :post,
        "/api/v1/auth/logout",
        %{
          "refresh_token" => "logout-session-refresh-token",
          "device_id" => fixture.device_id
        }
      )

    assert logout_conn.status == 204

    conn = session_request(access_token.token)

    assert conn.status == 401
    assert_session_invalid(conn)
  end

  @tag :postgres_integration
  test "POST /api/v1/auth/logout rejects invalid refresh token" do
    fixture = create_refresh_fixture!("real-logout-token")

    conn =
      json_request(
        :post,
        "/api/v1/auth/logout",
        %{
          "refresh_token" => "not-the-real-logout-token",
          "device_id" => fixture.device_id
        }
      )

    assert conn.status == 401
    assert_refresh_invalid(conn)
    assert Repo.get!(RefreshToken, fixture.refresh_token_id).revoked_at == nil
    assert Repo.get!(DeviceSession, fixture.session_id).revoked_at == nil
  end

  @tag :postgres_integration
  test "POST /api/v1/auth/logout rejects already revoked refresh token" do
    fixture =
      create_refresh_fixture!("already-revoked-logout-token", revoked_at: DateTime.utc_now())

    conn =
      json_request(
        :post,
        "/api/v1/auth/logout",
        %{
          "refresh_token" => "already-revoked-logout-token",
          "device_id" => fixture.device_id
        }
      )

    assert conn.status == 401
    assert_refresh_invalid(conn)
  end

  @tag :postgres_integration
  test "GET /api/v1/auth/session returns DB-backed session data for a valid access token" do
    fixture = create_refresh_fixture!("session-refresh-token")
    access_token = create_access_token!(fixture)

    conn = session_request(access_token.token)

    assert conn.status == 200
    response = Jason.decode!(conn.resp_body)

    assert response["user_id"] == fixture.user_id
    assert response["session_id"] == fixture.session_id
    assert response["device_id"] == fixture.device_id
    assert response["platform"] == "ios"
    assert response["issued_at"] == access_token.issued_at
    assert response["expires_at"] == access_token.expires_at
  end

  @tag :postgres_integration
  test "GET /api/v1/auth/session rejects missing Authorization header" do
    conn = session_request()

    assert conn.status == 401
    assert_session_invalid(conn)
  end

  @tag :postgres_integration
  test "GET /api/v1/auth/session rejects malformed Authorization header" do
    conn = session_request_with_header("Token malformed")

    assert conn.status == 401
    assert_session_invalid(conn)
  end

  @tag :postgres_integration
  test "GET /api/v1/auth/session rejects invalid access token" do
    conn = session_request("not-a-signed-envelope")

    assert conn.status == 401
    assert_session_invalid(conn)
  end

  @tag :postgres_integration
  test "GET /api/v1/auth/session rejects expired access token" do
    fixture = create_refresh_fixture!("expired-access-session-refresh-token")
    access_token = create_access_token!(fixture, expires_in_seconds: -60)

    conn = session_request(access_token.token)

    assert conn.status == 401
    assert_session_invalid(conn)
  end

  @tag :postgres_integration
  test "GET /api/v1/auth/session rejects revoked device session" do
    fixture = create_refresh_fixture!("revoked-session-refresh-token")
    access_token = create_access_token!(fixture)

    assert {:ok, _device_session} =
             AuthService.DeviceSessions.update_device_session(
               Repo.get!(DeviceSession, fixture.session_id),
               %{"revoked_at" => DateTime.utc_now()}
             )

    conn = session_request(access_token.token)

    assert conn.status == 401
    assert_session_invalid(conn)
  end

  @tag :postgres_integration
  test "GET /api/v1/auth/session rejects token for missing user" do
    fixture = create_refresh_fixture!("missing-user-session-refresh-token")
    access_token = create_access_token!(%{fixture | user_id: Ecto.UUID.generate()})

    conn = session_request(access_token.token)

    assert conn.status == 401
    assert_session_invalid(conn)
  end

  setup do
    previous_persistence = Application.get_env(:auth_service, :otp_request_persistence, false)

    previous_verify_persistence =
      Application.get_env(:auth_service, :otp_verify_persistence, false)

    previous_refresh_persistence =
      Application.get_env(:auth_service, :refresh_token_rotation_persistence, false)

    previous_logout_persistence = Application.get_env(:auth_service, :logout_persistence, false)
    previous_session_persistence = Application.get_env(:auth_service, :session_persistence, false)

    Application.put_env(:auth_service, :otp_request_persistence, true)
    Application.put_env(:auth_service, :otp_verify_persistence, true)
    Application.put_env(:auth_service, :refresh_token_rotation_persistence, true)
    Application.put_env(:auth_service, :logout_persistence, true)
    Application.put_env(:auth_service, :session_persistence, true)

    start_repo!(Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    on_exit(fn ->
      Application.put_env(:auth_service, :otp_request_persistence, previous_persistence)
      Application.put_env(:auth_service, :otp_verify_persistence, previous_verify_persistence)

      Application.put_env(
        :auth_service,
        :refresh_token_rotation_persistence,
        previous_refresh_persistence
      )

      Application.put_env(:auth_service, :logout_persistence, previous_logout_persistence)
      Application.put_env(:auth_service, :session_persistence, previous_session_persistence)
    end)

    :ok
  end

  defp json_request(method, path, params) do
    method
    |> conn(path, Jason.encode!(params))
    |> put_req_header("content-type", "application/json")
    |> ApiGatewayWeb.Endpoint.call([])
  end

  defp session_request(access_token \\ nil) do
    conn = conn(:get, "/api/v1/auth/session")

    conn =
      if access_token do
        put_req_header(conn, "authorization", "Bearer #{access_token}")
      else
        conn
      end

    ApiGatewayWeb.Endpoint.call(conn, [])
  end

  defp session_request_with_header(authorization) do
    :get
    |> conn("/api/v1/auth/session")
    |> put_req_header("authorization", authorization)
    |> ApiGatewayWeb.Endpoint.call([])
  end

  defp start_repo!(repo) do
    case repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp create_verification_code!(destination, code, opts \\ []) do
    otp_request_id = Ecto.UUID.generate()
    now = DateTime.utc_now()
    expires_in_seconds = Keyword.get(opts, :expires_in_seconds, 300)
    consumed_at = Keyword.get(opts, :consumed_at)

    assert {:ok, _verification_code} =
             VerificationCodes.create_verification_code(%{
               "id" => otp_request_id,
               "purpose" => "login",
               "destination" => destination,
               "code_hash" => AuthService.OTP.hash_code(destination, "login", code),
               "attempts" => 0,
               "expires_at" => DateTime.add(now, expires_in_seconds, :second),
               "consumed_at" => consumed_at
             })

    otp_request_id
  end

  defp create_user!(phone_number) do
    assert {:ok, user} =
             Accounts.create_user(%{
               "id" => Ecto.UUID.generate(),
               "phone_number" => phone_number,
               "status" => "active"
             })

    user
  end

  defp create_refresh_fixture!(raw_refresh_token, opts \\ []) do
    user = create_user!(unique_phone_number())
    device_id = "refresh-device-#{System.unique_integer([:positive])}"
    session_id = Ecto.UUID.generate()
    token_hash = Tokens.hash_token(raw_refresh_token)
    now = DateTime.utc_now()

    assert {:ok, device_session} =
             AuthService.DeviceSessions.create_device_session(%{
               "id" => session_id,
               "user_id" => user.id,
               "device_id" => device_id,
               "device_name" => "Refresh Test Device",
               "platform" => "ios",
               "refresh_token_hash" => token_hash,
               "last_seen_at" => now
             })

    assert {:ok, refresh_token} =
             RefreshTokens.create_refresh_token(%{
               "id" => Ecto.UUID.generate(),
               "user_id" => user.id,
               "device_id" => device_id,
               "token_hash" => token_hash,
               "expires_at" =>
                 DateTime.add(now, Keyword.get(opts, :expires_in_seconds, 300), :second),
               "revoked_at" => Keyword.get(opts, :revoked_at)
             })

    %{
      user_id: user.id,
      device_id: device_id,
      session_id: device_session.id,
      refresh_token_id: refresh_token.id
    }
  end

  defp create_access_token!(fixture, opts \\ []) do
    expires_in_seconds = Keyword.get(opts, :expires_in_seconds, 900)
    issued_at = DateTime.utc_now() |> DateTime.truncate(:second)
    expires_at = DateTime.add(issued_at, expires_in_seconds, :second)

    claims = %{
      "typ" => "access",
      "sub" => fixture.user_id,
      "sid" => fixture.session_id,
      "did" => fixture.device_id,
      "iat" => DateTime.to_unix(issued_at),
      "exp" => DateTime.to_unix(expires_at),
      "jti" => Ecto.UUID.generate(),
      "iss" => Tokens.token_issuer(),
      "aud" => Tokens.token_audience()
    }

    assert {:ok, access_token} = Tokens.sign_claims(claims)

    %{
      token: access_token,
      issued_at: DateTime.to_iso8601(issued_at),
      expires_at: DateTime.to_iso8601(expires_at)
    }
  end

  defp unique_phone_number do
    "+1555#{System.unique_integer([:positive])}"
  end

  defp assert_otp_invalid(conn) do
    assert_error_envelope(conn, "auth.otp_invalid", "OTP is wrong or expired")
  end

  defp assert_refresh_invalid(conn) do
    assert_error_envelope(conn, "auth.refresh_invalid", "Refresh token is invalid")
  end

  defp assert_session_invalid(conn) do
    assert_error_envelope(conn, "auth.session_invalid", "Session token is invalid")
  end

  defp assert_error_envelope(conn, code, message) do
    assert %{
             "error" => %{
               "code" => ^code,
               "message" => ^message,
               "correlation_id" => correlation_id
             }
           } = Jason.decode!(conn.resp_body)

    assert is_binary(correlation_id) and correlation_id != "" and
             correlation_id != "corr_placeholder"
  end
end
