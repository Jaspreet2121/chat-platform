defmodule AuthService.SmsOtpFallbackTest do
  @moduledoc """
  The 024 FALLBACK. The retriever decoration (`<#>` + hash lines) changes the text the provider matches
  against the DLT template — exactly. Until that template covers the decorated shape, a decorated send
  comes back ErrorCode 024, and a user must still get their OTP: the same code is resent ONCE as the
  plain approved body. Only a decorated 024 does this, and never more than twice.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AuthService.SmsClient

  @code "483920"
  @number "918377001500"
  @template "Your Growblic Chat OTP: {code} Valid for 5 min. Do not share. Growblic Private Limited"
  @plain "Your Growblic Chat OTP: 483920 Valid for 5 min. Do not share. Growblic Private Limited"

  setup do
    prev = Application.get_env(:auth_service, :sms)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:auth_service, :sms, prev),
        else: Application.delete_env(:auth_service, :sms)
    end)

    :ok
  end

  # Every request's `text` is sent to the test pid; `respond.(text)` picks the ErrorCode.
  defp stub(hashes, respond) do
    test_pid = self()

    plug = fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      text = conn.query_params["text"]
      send(test_pid, {:sms_text, text})
      code = respond.(text)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "ErrorCode" => code,
          "ErrorMessage" => if(code == "000", do: "Success", else: "Invalid Template")
        })
      )
    end

    Application.put_env(:auth_service, :sms,
      base_url: "https://www.smsgatewayhub.com",
      send_path: "/api/mt/SendSMS",
      api_key: "test-api-key",
      senderid: "CP-GROWOT-S",
      country_prefix: "91",
      otp_template: @template,
      retriever_app_hashes: hashes,
      req_options: [plug: plug]
    )
  end

  defp decorated?(text), do: String.starts_with?(text, "<#> ")

  test "a DECORATED body rejected with 024 is resent once as the plain approved body — the user still gets the OTP" do
    stub("68PGts+WCBC,ULFu0JUOYhW", fn text -> if decorated?(text), do: "024", else: "000" end)

    assert :ok = SmsClient.send_otp(@number, @code)

    assert_received {:sms_text, "<#> " <> _}
    assert_received {:sms_text, @plain}
    refute_received {:sms_text, _}
  end

  test "an accepted decorated body is sent once — no fallback" do
    stub("68PGts+WCBC", fn _ -> "000" end)

    assert :ok = SmsClient.send_otp(@number, @code)

    assert_received {:sms_text, "<#> " <> _}
    refute_received {:sms_text, _}
  end

  test "no hashes: a 024 on the plain body is returned as is — nothing plainer to fall back to" do
    stub(nil, fn _ -> "024" end)

    assert {:error, {"024", "Invalid Template"}} = SmsClient.send_otp(@number, @code)

    assert_received {:sms_text, @plain}
    refute_received {:sms_text, _}
  end

  test "only 024 falls back — any other rejection of the decorated body is returned without a resend" do
    stub("68PGts+WCBC", fn _ -> "025" end)

    assert {:error, {"025", "Invalid Template"}} = SmsClient.send_otp(@number, @code)

    assert_received {:sms_text, "<#> " <> _}
    refute_received {:sms_text, _}
  end

  test "if the plain resend is ALSO rejected, that is the answer — never a third attempt" do
    stub("68PGts+WCBC", fn _ -> "024" end)

    assert {:error, {"024", "Invalid Template"}} = SmsClient.send_otp(@number, @code)

    assert_received {:sms_text, "<#> " <> _}
    assert_received {:sms_text, @plain}
    refute_received {:sms_text, _}
  end

  test "the fallback path logs shape only — never the code, never the number" do
    log =
      capture_log(fn ->
        stub("68PGts+WCBC", fn text -> if decorated?(text), do: "024", else: "000" end)
        SmsClient.send_otp(@number, @code)
      end)

    assert log =~ "(024)"
    assert log =~ "otp sms built hashes=1"
    assert log =~ "otp sms built hashes=0"
    refute log =~ @code
    refute log =~ @number
    refute log =~ "8377001500"
  end
end
