defmodule AuthService.SmsFallbackTest do
  @moduledoc """
  THE PLAIN-BODY FALLBACK, and the production failure that showed it was keyed too narrowly.

  2026-09-17 14:45:36 and again at 14:46:24: the provider answered ErrorCode **"006" "Invalid
  template text"** for the retriever-decorated body. The fallback matched `"024"` alone, so neither
  OTP was ever resent and neither user received anything at all — the fallback existed and did
  nothing, twice, which is worse than not having one, because the log read like a handled case.

  Every test here uses the REAL code strings the provider sent.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AuthService.SmsClient

  @code "483920"
  @number "918377001500"
  @hash "68PGts+WCBC"
  @template "Your Growblic Chat OTP: {code} Valid for 5 min. Do not share. Growblic Private Limited"

  setup do
    prev = Application.get_env(:auth_service, :sms)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:auth_service, :sms, prev),
        else: Application.delete_env(:auth_service, :sms)
    end)

    :ok
  end

  # A provider that rejects the FIRST body with `code` and accepts anything after, recording every
  # `text` it was sent so the second attempt can be inspected.
  defp stub(code, hashes \\ @hash) do
    test_pid = self()
    counter = :counters.new(1, [])

    plug = fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      :counters.add(counter, 1, 1)
      attempt = :counters.get(counter, 1)
      send(test_pid, {:sms_attempt, attempt, conn.query_params["text"]})

      body =
        if attempt == 1 and code != nil do
          %{"ErrorCode" => code, "ErrorMessage" => message_for(code)}
        else
          %{"ErrorCode" => "000", "ErrorMessage" => "Success", "JobId" => "j1"}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
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
      otp_template: @template,
      retriever_app_hashes: hashes,
      req_options: [plug: plug]
    )
  end

  defp message_for("006"), do: "Invalid template text"
  defp message_for("024"), do: "Invalid Template"
  defp message_for(_), do: "Rejected"

  defp attempts(acc \\ []) do
    receive do
      {:sms_attempt, n, text} -> attempts([{n, text} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "MUT-1 guard: a 006 rejection resends the PLAIN body — the production failure" do
    stub("006")

    log = capture_log(fn -> assert :ok = SmsClient.send_otp(@number, @code) end)

    assert log =~ "otp sms fallback used code=006"

    sent = attempts()
    assert length(sent) == 2, "006 sent #{length(sent)} attempt(s) — the user got nothing"

    [{1, first}, {2, second}] = sent
    assert first =~ "<#>"
    refute second =~ "<#>"
  end

  test "024 still falls back — widening the set did not lose the case it was built for" do
    stub("024")

    log = capture_log(fn -> assert :ok = SmsClient.send_otp(@number, @code) end)

    assert log =~ "otp sms fallback used code=024"
    assert length(attempts()) == 2
  end

  test "MUT-4 guard: the plain resend carries NO `<#>` and NO hash lines" do
    stub("006")
    assert :ok = SmsClient.send_otp(@number, @code)

    [{1, decorated}, {2, plain}] = attempts()

    assert decorated =~ "<#>"
    assert decorated =~ @hash

    refute plain =~ "<#>"
    refute plain =~ @hash
    refute plain =~ "\n"

    assert plain ==
             "Your Growblic Chat OTP: #{@code} Valid for 5 min. Do not share. Growblic Private Limited"
  end

  test "MUT-3 guard: NEVER more than two attempts, even when the resend is rejected too" do
    test_pid = self()
    counter = :counters.new(1, [])

    plug = fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      :counters.add(counter, 1, 1)
      send(test_pid, {:sms_attempt, :counters.get(counter, 1), conn.query_params["text"]})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"ErrorCode" => "006", "ErrorMessage" => "Invalid template text"})
      )
    end

    stub("006")
    cfg = Application.get_env(:auth_service, :sms)
    Application.put_env(:auth_service, :sms, Keyword.put(cfg, :req_options, plug: plug))

    assert {:error, {"006", _}} = SmsClient.send_otp(@number, @code)

    assert length(attempts()) == 2,
           "a rejected resend must not retry again — two attempts, always"
  end

  test "MUT-2 guard: a NON-template rejection sends nothing more and surfaces as itself" do
    # Codes that must never cost a second credit: a bad key, a bad number, no balance.
    for code <- ["001", "003", "018", "999"] do
      stub(code)

      log =
        capture_log(fn -> assert {:error, {^code, _}} = SmsClient.send_otp(@number, @code) end)

      refute log =~ "otp sms fallback used",
             "#{code} triggered a resend — only a template rejection may"

      assert length(attempts()) == 1, "#{code} sent a second message"
    end
  end

  test "an UNDECORATED body that is rejected is returned as is — nothing plainer to try" do
    # No hashes configured, so the first body IS the plain one.
    stub("006", nil)

    log = capture_log(fn -> assert {:error, {"006", _}} = SmsClient.send_otp(@number, @code) end)

    refute log =~ "otp sms fallback used"
    assert length(attempts()) == 1
  end

  test "MUT-5 guard: the fallback path names the code it fired on" do
    stub("006")

    log = capture_log(fn -> SmsClient.send_otp(@number, @code) end)

    assert log =~ "otp sms fallback used code=006"
    # And still never the code or the number.
    refute log =~ @code
    refute log =~ @number
  end

  test "a SUCCESSFUL decorated send never falls back" do
    stub(nil)

    log = capture_log(fn -> assert :ok = SmsClient.send_otp(@number, @code) end)

    refute log =~ "otp sms fallback used"
    assert length(attempts()) == 1
  end

  test "the retryable set is exactly the two codes observed rejecting a body" do
    assert SmsClient.template_rejection_codes() == ["006", "024"]
  end
end
