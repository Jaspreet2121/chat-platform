defmodule AuthService.ReviewerLoginTest do
  @moduledoc """
  The Play-reviewer test login (2026-08-18): allowlist parsing (count-only logging), the SMS
  provider NEVER called for an allowlisted number (tripwire mock), the fixed code accepted on
  verify (and ONLY the fixed code — a wrong code fails normally), feature-off = fully normal path,
  and a non-allowlisted number untouched by the feature.
  """
  use AuthService.DataCase, async: false

  import ExUnit.CaptureLog

  alias AuthService.{OTP, OtpDelivery, ReviewerLogins, VerificationCodes}

  @reviewer "+15550100001"
  @fixed_code "731945"
  @other "+15550107777"
  @real_code "123456"

  setup do
    prev_verify = Application.get_env(:auth_service, :otp_verify_persistence, false)
    prev_sms = Application.get_env(:auth_service, :sms)
    prev_list = Application.get_env(:auth_service, :reviewer_test_logins)

    Application.put_env(:auth_service, :otp_verify_persistence, true)
    Application.put_env(:auth_service, :reviewer_test_logins, %{@reviewer => @fixed_code})

    on_exit(fn ->
      Application.put_env(:auth_service, :otp_verify_persistence, prev_verify)

      if prev_sms,
        do: Application.put_env(:auth_service, :sms, prev_sms),
        else: Application.delete_env(:auth_service, :sms)

      if prev_list,
        do: Application.put_env(:auth_service, :reviewer_test_logins, prev_list),
        else: Application.delete_env(:auth_service, :reviewer_test_logins)

      System.delete_env("REVIEWER_TEST_LOGINS")
    end)

    :ok
  end

  # The otp_delivery_test tripwire: a provider plug that shouts if any HTTP send happens.
  defp arm_provider_tripwire do
    test_pid = self()

    plug = fn conn ->
      send(test_pid, :provider_called)
      Plug.Conn.send_resp(conn, 200, Jason.encode!(%{"ErrorCode" => "000"}))
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
      country_prefix: "91",
      req_options: [plug: plug]
    )
  end

  defp code!(destination) do
    id = Ecto.UUID.generate()

    {:ok, _} =
      VerificationCodes.create_verification_code(%{
        "id" => id,
        "purpose" => "login",
        "destination" => destination,
        "code_hash" => OTP.hash_code(destination, "login", @real_code),
        "attempts" => 0,
        "expires_at" => DateTime.add(DateTime.utc_now(), 300, :second)
      })

    id
  end

  defp verify(id, destination, code) do
    OTP.verify_otp(%{
      "otp_request_id" => id,
      "phone_number" => destination,
      "otp_code" => code,
      "device_id" => "device-" <> Integer.to_string(System.unique_integer([:positive])),
      "platform" => "android"
    })
  end

  test "load/0 parses the env — count logged, values never; malformed entries dropped" do
    System.put_env(
      "REVIEWER_TEST_LOGINS",
      "+15550100001:731945, +15550100002:100200,garbage,short:12,+bad phone:123456"
    )

    log = capture_log(fn -> assert :ok = ReviewerLogins.load() end)

    assert log =~ "2 configured"
    assert log =~ "3 malformed entries DROPPED"
    # Values never appear in logs.
    refute log =~ "731945"
    refute log =~ "15550100001"

    assert ReviewerLogins.allowlisted?("+15550100001")
    assert ReviewerLogins.code_matches?("+15550100002", "100200")
    refute ReviewerLogins.code_matches?("+15550100001", "100200")
    refute ReviewerLogins.allowlisted?("garbage")

    # Empty env = feature off.
    System.put_env("REVIEWER_TEST_LOGINS", "")
    assert :ok = ReviewerLogins.load()
    refute ReviewerLogins.allowlisted?("+15550100001")
  end

  test "an allowlisted number NEVER reaches the SMS provider; a normal number does" do
    arm_provider_tripwire()

    assert :ok = OtpDelivery.deliver(@reviewer, "999999", "sms")
    refute_received :provider_called

    assert :ok = OtpDelivery.deliver("919999999999", "999999", "sms")
    assert_received :provider_called
  end

  @tag :postgres_integration
  test "verify accepts ONLY the fixed code for an allowlisted number (audit-logged, masked)" do
    id = code!(@reviewer)

    # Wrong code: the normal failure — and it charged an attempt like any other wrong guess.
    assert {:error, :otp_invalid} = verify(id, @reviewer, "000000")

    log =
      capture_log(fn ->
        assert {:ok, session} = verify(id, @reviewer, @fixed_code)
        assert is_binary(session.access_token)
      end)

    # The audit LINE carries the mask (last 4 only), never the full number. (Scoped to the audit
    # line: test-env DEBUG SQL echoes bound params, which prod's info level never emits.)
    assert [audit_line | _] =
             log |> String.split("\n") |> Enum.filter(&(&1 =~ "reviewer test login verified"))

    assert audit_line =~ "…0001"
    refute audit_line =~ @reviewer
  end

  @tag :postgres_integration
  test "the REAL delivered code still works for an allowlisted number (normal path intact)" do
    id = code!(@reviewer)
    assert {:ok, _session} = verify(id, @reviewer, @real_code)
  end

  @tag :postgres_integration
  test "feature OFF → the fixed code is rejected; non-allowlisted numbers are never affected" do
    Application.put_env(:auth_service, :reviewer_test_logins, %{})
    id = code!(@reviewer)
    assert {:error, :otp_invalid} = verify(id, @reviewer, @fixed_code)

    Application.put_env(:auth_service, :reviewer_test_logins, %{@reviewer => @fixed_code})
    other_id = code!(@other)
    # The reviewer's fixed code opens nothing for another number...
    assert {:error, :otp_invalid} = verify(other_id, @other, @fixed_code)
    # ...whose own real code works as ever.
    assert {:ok, _session} = verify(other_id, @other, @real_code)
  end
end
