defmodule AuthService.SmsClientTest do
  # async: false — sets :auth_service, :sms app env. Stubs Req's HTTP via a `plug:` function, so the
  # REAL SMSGatewayHub is NEVER called.
  use ExUnit.Case, async: false

  alias AuthService.SmsClient

  setup do
    prev = Application.get_env(:auth_service, :sms)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:auth_service, :sms, prev),
        else: Application.delete_env(:auth_service, :sms)
    end)

    :ok
  end

  # Configure :sms with a Req `plug:` stub that captures the query params (sent to the test pid) and
  # returns a canned SMSGatewayHub JSON response with `error_code`.
  defp stub_provider(error_code) do
    test_pid = self()

    plug = fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:sms_request, conn.query_params})

      message = if error_code == "000", do: "Success", else: "Invalid Template"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"ErrorCode" => error_code, "ErrorMessage" => message})
      )
    end

    Application.put_env(:auth_service, :sms,
      enabled: true,
      base_url: "https://www.smsgatewayhub.com",
      send_path: "/api/mt/SendSMS",
      api_key: "test-api-key",
      senderid: "ISOOBC",
      channel: "2",
      dcs: "0",
      flashsms: "0",
      route: "31",
      entity_id: "ENTITY-123",
      template_login_id: "TEMPLATE-LOGIN-456",
      country_prefix: "91",
      req_options: [plug: plug]
    )
  end

  test "builds the correct params + DLT text and treats ErrorCode 000 as :ok" do
    stub_provider("000")

    assert :ok = SmsClient.send_otp("9876543210", "4321")

    assert_received {:sms_request, params}
    assert params["text"] == "Dear user, your login OTP is 4321 1500BC"
    assert params["number"] == "919876543210"
    assert params["APIKey"] == "test-api-key"
    assert params["senderid"] == "ISOOBC"
    assert params["channel"] == "2"
    assert params["DCS"] == "0"
    assert params["flashsms"] == "0"
    assert params["route"] == "31"
    assert params["EntityId"] == "ENTITY-123"
    assert params["templateid"] == "TEMPLATE-LOGIN-456"
  end

  test "non-000 ErrorCode (e.g. 024 template mismatch) -> {:error, {code, message}}" do
    stub_provider("024")

    assert {:error, {"024", "Invalid Template"}} = SmsClient.send_otp("9876543210", "4321")
  end

  test "format_number bridges a bare 10-digit number to country-code form; passes through full numbers" do
    assert SmsClient.format_number("9876543210", "91") == "919876543210"
    assert SmsClient.format_number("+91 98765 43210", "91") == "919876543210"
    assert SmsClient.format_number("919876543210", "91") == "919876543210"
  end

  test "otp_text matches the DLT-approved LOGIN template verbatim" do
    assert SmsClient.otp_text("4321") == "Dear user, your login OTP is 4321 1500BC"
  end

  test "otp_text renders a CONFIGURED template, substituting every {code}" do
    Application.put_env(:auth_service, :sms, otp_template: "Your Growblic OTP is {code}. Valid 10 min.")

    assert SmsClient.otp_text("9999") == "Your Growblic OTP is 9999. Valid 10 min."
  end
end
