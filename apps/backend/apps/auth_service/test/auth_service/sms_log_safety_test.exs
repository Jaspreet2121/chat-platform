defmodule AuthService.SmsLogSafetyTest do
  @moduledoc """
  WHAT THE OTP SEND IS ALLOWED TO LOG. One line per send, naming only SHAPE: how many retriever
  hashes rode along, and how long the body was.

  The OTP code and the destination number must never appear. An OTP in a log is an OTP in whatever
  aggregates the logs, for as long as that keeps them — and a phone number there is a separate
  disclosure again. This asserts against the FULL captured log of a real send through the client,
  not against one formatted string, so a line added anywhere in the path is caught.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AuthService.SmsClient

  @code "483920"
  @number "918377001500"
  @debug_hash "68PGts+WCBC"
  @release_hash "ULFu0JUOYhW"

  setup do
    prev = Application.get_env(:auth_service, :sms)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:auth_service, :sms, prev),
        else: Application.delete_env(:auth_service, :sms)
    end)

    :ok
  end

  defp stub(hashes) do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"ErrorCode" => "000", "ErrorMessage" => "Success"})
      )
    end

    Application.put_env(:auth_service, :sms,
      enabled: true,
      base_url: "https://www.smsgatewayhub.com",
      send_path: "/api/mt/SendSMS",
      api_key: "test-api-key",
      senderid: "CP-GROWOT-S",
      channel: "2",
      dcs: "0",
      flashsms: "0",
      route: "31",
      entity_id: "ENTITY-123",
      template_login_id: "TEMPLATE-LOGIN-456",
      country_prefix: "91",
      otp_template:
        "Your Growblic Chat OTP: {code} Valid for 5 min. Do not share. Growblic Private Limited",
      retriever_app_hashes: hashes,
      req_options: [plug: plug]
    )
  end

  test "the send logs shape ONLY — hashes and length, at info" do
    stub("#{@debug_hash},#{@release_hash}")

    log = capture_log([level: :info], fn -> assert :ok = SmsClient.send_otp(@number, @code) end)

    assert log =~ "otp sms built hashes=2 len=115"
  end

  test "MUT-4 guard: neither the CODE nor the NUMBER appears anywhere in the log" do
    stub("#{@debug_hash},#{@release_hash}")

    log = capture_log([level: :debug], fn -> assert :ok = SmsClient.send_otp(@number, @code) end)

    refute log =~ @code, "the OTP code reached a log line"
    refute log =~ @number, "the destination number reached a log line"
    # Not even the national part of the number, which is what a lookup would use.
    refute log =~ "8377001500"
    # The body itself must not be logged either — it CONTAINS the code.
    refute log =~ "Growblic Chat OTP"
  end

  test "the count is honest with no hashes configured, and still says nothing else" do
    stub(nil)

    log = capture_log([level: :debug], fn -> assert :ok = SmsClient.send_otp(@number, @code) end)

    assert log =~ "otp sms built hashes=0 len=86"
    refute log =~ @code
    refute log =~ @number
  end

  test "a provider FAILURE is logged without the code or the number either" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"ErrorCode" => "024", "ErrorMessage" => "Invalid Template"})
      )
    end

    stub("#{@debug_hash}")
    cfg = Application.get_env(:auth_service, :sms)
    Application.put_env(:auth_service, :sms, Keyword.put(cfg, :req_options, plug: plug))

    log = capture_log(fn -> assert {:error, _} = SmsClient.send_otp(@number, @code) end)

    assert log =~ "024"
    refute log =~ @code
    refute log =~ @number
  end
end
