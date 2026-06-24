defmodule AuthService.OtpDeliveryTest do
  # async: false — toggles :auth_service, :sms app env.
  use ExUnit.Case, async: false

  alias AuthService.OtpDelivery

  setup do
    prev = Application.get_env(:auth_service, :sms)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:auth_service, :sms, prev),
        else: Application.delete_env(:auth_service, :sms)
    end)

    :ok
  end

  # A plug stub that would shout if the provider were ever called.
  defp tripwire_config(enabled) do
    test_pid = self()

    plug = fn conn ->
      send(test_pid, :provider_called)
      Plug.Conn.send_resp(conn, 200, Jason.encode!(%{"ErrorCode" => "000"}))
    end

    Application.put_env(:auth_service, :sms,
      enabled: enabled,
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
  end

  test "with SMS delivery DISABLED (the default), deliver/3 does NOT call the provider" do
    tripwire_config(false)

    assert :ok = OtpDelivery.deliver("919999999999", "4321", "sms")

    refute_received :provider_called
  end

  test "email delivery is a no-op (separate future channel), never calls the SMS provider" do
    tripwire_config(true)

    assert :ok = OtpDelivery.deliver("user@example.test", "4321", "email")

    refute_received :provider_called
  end

  test "with SMS ENABLED, deliver/3 routes an sms to the provider" do
    tripwire_config(true)

    assert :ok = OtpDelivery.deliver("919999999999", "4321", "sms")

    assert_received :provider_called
  end
end
