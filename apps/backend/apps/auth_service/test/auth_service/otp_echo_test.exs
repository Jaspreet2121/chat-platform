defmodule AuthService.OtpEchoTest do
  # async: false — toggles :auth_service, :otp_delivery_mode app env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AuthService.OtpDelivery

  setup do
    prev = Application.get_env(:auth_service, :otp_delivery_mode)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:auth_service, :otp_delivery_mode, prev),
        else: Application.delete_env(:auth_service, :otp_delivery_mode)
    end)

    :ok
  end

  test "echo mode surfaces the plaintext code in the response (debug_code)" do
    Application.put_env(:auth_service, :otp_delivery_mode, "echo")

    response = OtpDelivery.echo_code(%{otp_request_id: "req-1", delivery_method: "sms"}, "4321")

    assert response[:debug_code] == "4321"
    # original fields preserved
    assert response[:otp_request_id] == "req-1"
  end

  test "default (none) mode does NOT surface the code — the prod-safe default" do
    # Unset → defaults to "none".
    Application.delete_env(:auth_service, :otp_delivery_mode)
    refute Map.has_key?(OtpDelivery.echo_code(%{otp_request_id: "req-1"}, "4321"), :debug_code)

    # Explicit "none" → same.
    Application.put_env(:auth_service, :otp_delivery_mode, "none")
    refute Map.has_key?(OtpDelivery.echo_code(%{otp_request_id: "req-1"}, "4321"), :debug_code)
  end

  test "log mode logs the code but does NOT put it in the response" do
    Application.put_env(:auth_service, :otp_delivery_mode, "log")

    log =
      capture_log(fn ->
        assert :ok = OtpDelivery.deliver("919999999999", "4321", "email")
      end)

    assert log =~ "4321"
    refute Map.has_key?(OtpDelivery.echo_code(%{otp_request_id: "req-1"}, "4321"), :debug_code)
  end
end
