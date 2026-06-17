defmodule AuthService.PersistenceBoundariesTest do
  use ExUnit.Case, async: true

  @user_id "11111111-1111-1111-1111-111111111111"
  @now DateTime.utc_now()
       |> DateTime.truncate(:microsecond)

  test "Accounts builds users_auth changesets for future repo writes" do
    changeset =
      AuthService.Accounts.user_changeset(%{
        "phone_number" => "+919999999999",
        "status" => "active"
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :phone_number) == "+919999999999"
  end

  test "VerificationCodes builds verification code changesets" do
    changeset =
      AuthService.VerificationCodes.verification_code_changeset(%{
        "purpose" => "login",
        "destination" => "+919999999999",
        "code_hash" => "code_hash_placeholder",
        "expires_at" => @now
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :purpose) == "login"
  end

  test "DeviceSessions builds device session changesets" do
    changeset =
      AuthService.DeviceSessions.device_session_changeset(%{
        "user_id" => @user_id,
        "device_id" => "dev_123",
        "platform" => "ios",
        "refresh_token_hash" => "refresh_hash_placeholder"
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :platform) == "ios"
  end

  test "RefreshTokens builds create and revoke changesets" do
    changeset =
      AuthService.RefreshTokens.refresh_token_changeset(%{
        "user_id" => @user_id,
        "device_id" => "dev_123",
        "token_hash" => "refresh_hash_placeholder",
        "expires_at" => @now
      })

    assert changeset.valid?

    revoke_changeset =
      %AuthService.Schemas.RefreshToken{}
      |> AuthService.Schemas.RefreshToken.revoke_changeset(%{"revoked_at" => @now})

    assert revoke_changeset.valid?
    assert Ecto.Changeset.get_field(revoke_changeset, :revoked_at) == @now
  end

  test "LoginAttempts builds audit changesets" do
    changeset =
      AuthService.LoginAttempts.login_attempt_changeset(%{
        "login_identifier" => "+919999999999",
        "success" => true
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :success) == true
  end
end
