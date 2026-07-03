defmodule AuthService.SMSTest do
  # async: false — toggles the :auth_service, :sms app env (provider selection).
  use ExUnit.Case, async: false

  alias AuthService.SMS

  setup do
    prev = Application.get_env(:auth_service, :sms)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:auth_service, :sms, prev),
        else: Application.delete_env(:auth_service, :sms)
    end)

    :ok
  end

  defp put_sms(opts), do: Application.put_env(:auth_service, :sms, opts)

  test "defaults to the console provider (no real SMS) when nothing is configured" do
    put_sms([])

    assert SMS.provider() == "console"
    assert :ok = SMS.send_otp("919999999999", "4321")
  end

  test "SMS_PROVIDER=console returns :ok and NEVER calls the gateway" do
    test_pid = self()
    plug = fn conn ->
      send(test_pid, :provider_called)
      Plug.Conn.send_resp(conn, 200, "{}")
    end

    put_sms(provider: "console", req_options: [plug: plug])

    assert :ok = SMS.send_otp("919999999999", "4321")
    refute_received :provider_called
  end

  test "SMS_PROVIDER=smsgatewayhub routes to the SMSGatewayHub adapter" do
    test_pid = self()
    plug = fn conn ->
      send(test_pid, :provider_called)
      Plug.Conn.send_resp(conn, 200, Jason.encode!(%{"ErrorCode" => "000"}))
    end

    put_sms(
      provider: "smsgatewayhub",
      base_url: "https://www.smsgatewayhub.com",
      send_path: "/api/mt/SendSMS",
      api_key: "test-api-key",
      senderid: "ISOOBC",
      channel: "2",
      dcs: "0",
      flashsms: "0",
      country_prefix: "91",
      req_options: [plug: plug]
    )

    assert :ok = SMS.send_otp("9876543210", "4321")
    assert_received :provider_called
  end

  test "legacy OTP_SMS_DELIVERY_ENABLED=true maps to smsgatewayhub when SMS_PROVIDER is unset" do
    put_sms(enabled: true)
    assert SMS.provider() == "smsgatewayhub"
  end

  test "explicit SMS_PROVIDER supersedes the legacy enabled flag" do
    put_sms(provider: "console", enabled: true)
    assert SMS.provider() == "console"
  end
end
