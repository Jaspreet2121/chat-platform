defmodule AuthService.AuthCoreTest do
  use ExUnit.Case, async: false

  @secret "test-secret-for-auth-core"
  @now ~U[2026-06-17 00:00:00Z]

  test "OTP helpers generate fixed-width codes and verify scoped hashes" do
    code = AuthService.OTP.generate_code()

    assert String.length(code) == 6
    assert code =~ ~r/^\d{6}$/

    code_hash = AuthService.OTP.hash_code("+919999999999", "login", "123456", @secret)

    assert AuthService.OTP.valid_code?("+919999999999", "login", "123456", code_hash, @secret)
    refute AuthService.OTP.valid_code?("+919999999999", "signup", "123456", code_hash, @secret)
    refute AuthService.OTP.valid_code?("+919999999999", "login", "000000", code_hash, @secret)
  end

  test "OTP helper builds verification-code persistence attrs" do
    attrs =
      AuthService.OTP.build_verification_attrs(
        %{"destination" => "User@Example.com", "purpose" => "email_verify", "code" => "123456"},
        now: @now,
        ttl_seconds: 120,
        secret: @secret
      )

    assert attrs["purpose"] == "email_verify"
    assert attrs["destination"] == "User@Example.com"
    assert attrs["attempts"] == 0
    assert attrs["expires_at"] == ~U[2026-06-17 00:02:00Z]

    assert AuthService.OTP.valid_code?(
             "user@example.com",
             "email_verify",
             "123456",
             attrs["code_hash"],
             @secret
           )
  end

  test "OTP request helper builds contract response and stores only hashed code attrs" do
    assert {:ok, request} =
             AuthService.OTP.prepare_request(
               %{"phone_number" => "+919999999999", "purpose" => "login"},
               otp_request_id: "22222222-2222-2222-2222-222222222222",
               code: "123456",
               now: @now,
               secret: @secret
             )

    assert request.response == %{
             otp_request_id: "22222222-2222-2222-2222-222222222222",
             delivery_method: "sms",
             expires_in_seconds: 300,
             retry_after_seconds: 60
           }

    assert request.verification_attrs["id"] == "22222222-2222-2222-2222-222222222222"
    assert request.verification_attrs["purpose"] == "login"
    assert request.verification_attrs["destination"] == "+919999999999"
    assert request.verification_attrs["attempts"] == 0
    assert request.verification_attrs["consumed_at"] == nil
    assert request.verification_attrs["expires_at"] == ~U[2026-06-17 00:05:00Z]
    refute "123456" in Map.values(request.verification_attrs)

    assert AuthService.OTP.valid_code?(
             "+919999999999",
             "login",
             "123456",
             request.verification_attrs["code_hash"],
             @secret
           )
  end

  test "token helpers sign and verify expiring claims" do
    claims = %{
      "typ" => "access",
      "sub" => Ecto.UUID.generate(),
      "exp" => DateTime.to_unix(DateTime.add(@now, 60, :second))
    }

    assert {:ok, token} = AuthService.Tokens.sign_claims(claims, secret: @secret)

    assert {:ok, ^claims} =
             AuthService.Tokens.verify_signed_token(token, secret: @secret, now: @now)

    expired_now = DateTime.add(@now, 90, :second)

    assert AuthService.Tokens.verify_signed_token(token, secret: @secret, now: expired_now) ==
             {:error, :expired}
  end

  test "token helper rejects tampered signatures" do
    assert {:ok, token} =
             AuthService.Tokens.sign_claims(
               %{"typ" => "access", "exp" => DateTime.to_unix(DateTime.add(@now, 60, :second))},
               secret: @secret
             )

    [version, payload, signature] = String.split(token, ".", parts: 3)
    tampered_signature = String.duplicate("a", byte_size(signature))
    tampered_token = Enum.join([version, payload, tampered_signature], ".")

    assert AuthService.Tokens.verify_signed_token(tampered_token, secret: @secret, now: @now) ==
             {:error, :invalid_signature}
  end

  test "token helper prepares issue-pair persistence attrs" do
    user_id = Ecto.UUID.generate()

    assert {:ok, token_pair} =
             AuthService.Tokens.prepare_issue_pair(
               %{
                 user_id: user_id,
                 device_id: "device-123",
                 device_name: "Browser",
                 platform: "web"
               },
               secret: @secret,
               now: @now
             )

    assert token_pair.access_token_expires_in_seconds == 900
    assert token_pair.refresh_token_expires_in_seconds == 2_592_000
    assert token_pair.refresh_token_attrs["user_id"] == user_id
    assert token_pair.refresh_token_attrs["device_id"] == "device-123"

    assert token_pair.refresh_token_attrs["token_hash"] ==
             AuthService.Tokens.hash_token(token_pair.refresh_token, @secret)

    assert token_pair.device_session_attrs["refresh_token_hash"] ==
             token_pair.refresh_token_attrs["token_hash"]

    assert {:ok, claims} =
             AuthService.Tokens.verify_signed_token(token_pair.access_token,
               secret: @secret,
               now: @now
             )

    assert claims["sub"] == user_id
    assert claims["did"] == "device-123"
    assert claims["iss"] == "chat-platform"
    assert claims["aud"] == "chat-platform-clients"
  end

  test "token helper exposes config-backed token settings" do
    previous_config = Application.get_env(:auth_service, :tokens, [])

    Application.put_env(:auth_service, :tokens,
      access_token_ttl_seconds: 120,
      refresh_token_ttl_seconds: 240,
      issuer: "test-issuer",
      audience: "test-audience"
    )

    on_exit(fn -> Application.put_env(:auth_service, :tokens, previous_config) end)

    assert AuthService.Tokens.access_token_ttl_seconds() == 120
    assert AuthService.Tokens.refresh_token_ttl_seconds() == 240
    assert AuthService.Tokens.token_issuer() == "test-issuer"
    assert AuthService.Tokens.token_audience() == "test-audience"

    assert {:ok, token_pair} =
             AuthService.Tokens.prepare_issue_pair(
               %{
                 user_id: Ecto.UUID.generate(),
                 device_id: "device-123",
                 platform: "web"
               },
               secret: @secret,
               now: @now
             )

    assert token_pair.access_token_expires_in_seconds == 120
    assert token_pair.refresh_token_expires_in_seconds == 240

    assert {:ok, claims} =
             AuthService.Tokens.verify_signed_token(token_pair.access_token,
               secret: @secret,
               now: @now
             )

    assert claims["iss"] == "test-issuer"
    assert claims["aud"] == "test-audience"
  end

  test "token helper prepares refresh-token rotation attrs" do
    user_id = Ecto.UUID.generate()

    assert {:ok, rotation} =
             AuthService.Tokens.prepare_refresh_rotation(
               "old-refresh-token",
               %{"user_id" => user_id, "device_id" => "device-123"},
               secret: @secret,
               now: @now
             )

    assert rotation.presented_token_hash ==
             AuthService.Tokens.hash_token("old-refresh-token", @secret)

    assert rotation.new_refresh_token_attrs["user_id"] == user_id
    assert rotation.new_refresh_token_attrs["device_id"] == "device-123"
    assert rotation.revoke_existing_attrs["revoked_at"] == @now

    assert rotation.revoke_existing_attrs["replaced_by_token_id"] ==
             rotation.new_refresh_token_attrs["id"]
  end

  test "rate-limit helper builds stable Redis counter plans" do
    plan =
      AuthService.RateLimits.attempt_plan(%{
        scope: "OTP_REQUEST",
        identifier: " User@Example.com ",
        metadata: %{ip_address: "127.0.0.1"}
      })

    assert plan.scope == "otp_request"
    assert plan.limit == 5
    assert plan.window_seconds == 900
    assert plan.identifier == "user@example.com"
    assert plan.metadata == %{ip_address: "127.0.0.1"}

    assert plan.key ==
             AuthService.RateLimits.counter_key(%{
               scope: "otp_request",
               identifier: "user@example.com"
             })
  end
end
