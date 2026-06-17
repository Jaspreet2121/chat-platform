defmodule AuthService.BoundariesTest do
  use ExUnit.Case, async: true

  test "OTP boundary returns contract-aligned placeholders" do
    assert {:ok, otp_request} = AuthService.OTP.request_otp(%{})
    assert otp_request.otp_request_id == "otp_req_placeholder"
    assert otp_request.delivery_method == "sms"
    assert otp_request.expires_in_seconds == 300

    assert {:ok, otp_verify} = AuthService.OTP.verify_otp(%{})
    assert otp_verify.user_id == "user_placeholder"
    assert otp_verify.session_id == "sess_placeholder"
    assert otp_verify.access_token == "access_token_placeholder"
    assert otp_verify.refresh_token == "refresh_token_placeholder"
  end

  test "Tokens boundary returns contract-aligned placeholders" do
    assert AuthService.Tokens.issue_pair(%{}) == {:error, :not_implemented}

    assert {:ok, refresh} = AuthService.Tokens.refresh(%{})
    assert refresh.access_token == "new_access_token_placeholder"
    assert refresh.refresh_token == "new_refresh_token_placeholder"

    assert AuthService.Tokens.revoke(%{}) == {:ok, %{}}
  end

  test "Sessions boundary returns contract-aligned placeholders" do
    assert AuthService.Sessions.create_session(%{}) == {:error, :not_implemented}

    assert {:ok, session} = AuthService.Sessions.current_session(%{})
    assert session.session_id == "sess_placeholder"
    assert session.user_id == "user_placeholder"
    assert session.device_id == "device_placeholder"

    assert AuthService.Sessions.revoke_session(%{}) == {:error, :not_implemented}
  end

  test "Devices boundary is a placeholder" do
    assert AuthService.Devices.register_device(%{}) == {:error, :not_implemented}
    assert AuthService.Devices.get_device(%{}) == {:error, :not_implemented}
    assert AuthService.Devices.touch_device(%{}) == {:error, :not_implemented}
  end

  test "RateLimits boundary is a placeholder" do
    assert AuthService.RateLimits.check(%{}) == {:error, :not_implemented}
    assert AuthService.RateLimits.record_attempt(%{}) == {:error, :not_implemented}
  end
end
