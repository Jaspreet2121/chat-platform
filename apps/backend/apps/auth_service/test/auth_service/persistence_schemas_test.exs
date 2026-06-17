defmodule AuthService.PersistenceSchemasTest do
  use ExUnit.Case, async: true

  alias AuthService.Schemas.DeviceSession
  alias AuthService.Schemas.LoginAttempt
  alias AuthService.Schemas.RefreshToken
  alias AuthService.Schemas.UserAuth
  alias AuthService.Schemas.VerificationCode

  @user_id "11111111-1111-1111-1111-111111111111"
  @now DateTime.utc_now()
       |> DateTime.truncate(:microsecond)

  test "users_auth changeset requires phone or email and validates status" do
    assert UserAuth.changeset(%UserAuth{}, %{"phone_number" => "+919999999999"}).valid?
    assert UserAuth.changeset(%UserAuth{}, %{"email" => "user@example.com"}).valid?

    missing_contact = UserAuth.changeset(%UserAuth{}, %{})
    refute missing_contact.valid?
    assert Keyword.has_key?(missing_contact.errors, :phone_number)

    invalid_status =
      UserAuth.changeset(%UserAuth{}, %{
        "phone_number" => "+919999999999",
        "status" => "pending"
      })

    refute invalid_status.valid?
    assert Keyword.has_key?(invalid_status.errors, :status)
  end

  test "verification_codes changeset validates purpose and attempts" do
    assert VerificationCode.changeset(%VerificationCode{}, %{
             "purpose" => "login",
             "destination" => "+919999999999",
             "code_hash" => "hash_placeholder",
             "expires_at" => @now
           }).valid?

    invalid =
      VerificationCode.changeset(%VerificationCode{}, %{
        "purpose" => "password_reset",
        "destination" => "+919999999999",
        "code_hash" => "hash_placeholder",
        "attempts" => -1,
        "expires_at" => @now
      })

    refute invalid.valid?
    assert Keyword.has_key?(invalid.errors, :purpose)
    assert Keyword.has_key?(invalid.errors, :attempts)
  end

  test "device_sessions changeset validates required fields and platform" do
    assert DeviceSession.changeset(%DeviceSession{}, %{
             "user_id" => @user_id,
             "device_id" => "dev_123",
             "platform" => "ios",
             "refresh_token_hash" => "refresh_hash_placeholder"
           }).valid?

    invalid =
      DeviceSession.changeset(%DeviceSession{}, %{
        "user_id" => @user_id,
        "device_id" => "dev_123",
        "platform" => "desktop",
        "refresh_token_hash" => "refresh_hash_placeholder"
      })

    refute invalid.valid?
    assert Keyword.has_key?(invalid.errors, :platform)
  end

  test "refresh_tokens changeset validates token persistence fields" do
    assert RefreshToken.changeset(%RefreshToken{}, %{
             "user_id" => @user_id,
             "device_id" => "dev_123",
             "token_hash" => "refresh_hash_placeholder",
             "expires_at" => @now
           }).valid?

    invalid = RefreshToken.changeset(%RefreshToken{}, %{"device_id" => "dev_123"})

    refute invalid.valid?
    assert Keyword.has_key?(invalid.errors, :user_id)
    assert Keyword.has_key?(invalid.errors, :token_hash)
    assert Keyword.has_key?(invalid.errors, :expires_at)
  end

  test "login_attempts changeset tracks successful and failed attempts" do
    assert LoginAttempt.changeset(%LoginAttempt{}, %{
             "login_identifier" => "+919999999999",
             "user_id" => @user_id,
             "success" => false,
             "failure_reason" => "otp_invalid"
           }).valid?

    invalid = LoginAttempt.changeset(%LoginAttempt{}, %{"success" => true})

    refute invalid.valid?
    assert Keyword.has_key?(invalid.errors, :login_identifier)
  end
end
