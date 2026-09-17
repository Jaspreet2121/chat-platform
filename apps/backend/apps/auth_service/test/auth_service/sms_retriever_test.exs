defmodule AuthService.SmsRetrieverTest do
  @moduledoc """
  THE SMS RETRIEVER DECORATION, against the body measured on a real SIM.

  On 2026-09-19 the delivered text was the approved wording and nothing else, and Android logged
  "No matching message is found". The API matches on two structural markers the message did not
  carry: a leading `<#>`, and a line holding the 11-character hash of the listening APK. Wording is
  never enough — these tests assert the markers, the multi-hash shape that lets one message serve
  two signing certs during a rollout, and the properties a login must never lose to any of it.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AuthService.{SmsClient, SmsRetriever}

  # The DLT-approved wording now in production, verbatim, with {code} where the OTP goes.
  @prod_template "Your Growblic Chat OTP: {code} Valid for 5 min. Do not share. Growblic Private Limited"

  # The real hashes: the re-signed debug build on the test phones, and the release/upload cert.
  @debug_hash "68PGts+WCBC"
  @release_hash "ULFu0JUOYhW"

  setup do
    previous = Application.get_env(:auth_service, :sms, [])

    on_exit(fn -> Application.put_env(:auth_service, :sms, previous) end)
    :ok
  end

  defp configure(hashes, template \\ @prod_template) do
    Application.put_env(:auth_service, :sms,
      otp_template: template,
      retriever_app_hashes: hashes
    )
  end

  describe "the rendered body" do
    test "MUT-1/MUT-2 guard: the `<#>` prefix AND every hash, each on its own line" do
      configure("#{@debug_hash},#{@release_hash}")

      body = SmsClient.otp_text("123456")

      assert body ==
               "<#> Your Growblic Chat OTP: 123456 Valid for 5 min. Do not share. " <>
                 "Growblic Private Limited\n\n#{@debug_hash}\n#{@release_hash}"

      lines = String.split(body, "\n")
      assert String.starts_with?(hd(lines), "<#> ")
      # Exactly one blank line separates the text from the hashes.
      assert Enum.at(lines, 1) == ""
      assert Enum.drop(lines, 2) == [@debug_hash, @release_hash]
    end

    test "ONE hash configured → one line; the multi-hash form is what serves a rollout" do
      configure(@debug_hash)
      one = SmsClient.otp_text("123456")
      assert String.ends_with?(one, "\n\n#{@debug_hash}")
      refute one =~ @release_hash

      # Both builds at once: Android matches if ANY line is its hash.
      configure("#{@debug_hash},#{@release_hash}")
      both = SmsClient.otp_text("123456")
      assert both =~ @debug_hash
      assert both =~ @release_hash
    end

    test "MUT-3 guard: the code is a STANDALONE 6-digit token, and the only one" do
      configure("#{@debug_hash},#{@release_hash}")
      body = SmsClient.otp_text("123456")

      # Exactly what Android's parser looks for: one 6-digit run with no digit either side.
      assert Regex.scan(~r/(?<!\d)\d{6}(?!\d)/, body) == [["123456"]]

      # And it is a whole word — not glued to "OTP:" or to "Valid".
      assert body =~ ~r/(?<![^\s])123456(?![^\s])/
      assert body =~ " 123456 "
    end

    test "MUT-5 guard: absent or empty config renders TODAY's body, byte-identical" do
      plain =
        "Your Growblic Chat OTP: 123456 Valid for 5 min. Do not share. Growblic Private Limited"

      for hashes <- [nil, "", "   ", ",", " , ", []] do
        configure(hashes)

        assert SmsClient.otp_text("123456") == plain,
               "#{inspect(hashes)} must fall back to the plain body, not decorate or fail"

        refute SmsClient.otp_text("123456") =~ "<#>"
      end
    end

    test "a malformed entry is skipped, not sent — and never raises" do
      configure(" #{@debug_hash} , , #{@release_hash} ")
      body = SmsClient.otp_text("123456")
      assert String.split(body, "\n") |> Enum.drop(2) == [@debug_hash, @release_hash]
    end

    test "the DLT-approved wording itself is untouched by the decoration" do
      configure("#{@debug_hash},#{@release_hash}")
      body = SmsClient.otp_text("123456")

      assert body =~
               "Your Growblic Chat OTP: 123456 Valid for 5 min. Do not share. Growblic Private Limited"
    end
  end

  describe "length" do
    test "MUT-6 guard: the real body with one hash, and with two, is inside 140 bytes" do
      configure(@debug_hash)
      one = SmsClient.otp_text("123456")
      assert byte_size(one) == 103
      assert byte_size(one) <= SmsRetriever.max_bytes()

      configure("#{@debug_hash},#{@release_hash}")
      two = SmsClient.otp_text("123456")
      assert byte_size(two) == 115
      assert byte_size(two) <= SmsRetriever.max_bytes()

      # Plain ASCII — one GSM-7 segment, not a UCS-2 message at half the capacity.
      assert two == :binary.bin_to_list(two) |> List.to_string()
      assert Enum.all?(:binary.bin_to_list(two), &(&1 < 128))
    end

    test "an OVERSIZE configuration warns ONCE at boot, and the warning names the size" do
      :persistent_term.erase({SmsRetriever, :oversize_warned})
      configure("#{@debug_hash},#{@release_hash}", String.duplicate("x", 150) <> " {code}")

      log =
        capture_log([level: :warning], fn ->
          size = SmsRetriever.warn_if_oversized(&SmsClient.otp_body/1)
          assert size > SmsRetriever.max_bytes()
        end)

      assert log =~ "over the 140-byte limit"
      assert log =~ "will SPLIT"

      # ONCE: a second boot-time call says nothing more.
      log =
        capture_log([level: :warning], fn ->
          SmsRetriever.warn_if_oversized(&SmsClient.otp_body/1)
        end)

      refute log =~ "140-byte limit"
    after
      :persistent_term.erase({SmsRetriever, :oversize_warned})
    end

    test "a body INSIDE the limit warns about nothing" do
      :persistent_term.erase({SmsRetriever, :oversize_warned})
      configure("#{@debug_hash},#{@release_hash}")

      log =
        capture_log([level: :warning], fn ->
          assert SmsRetriever.warn_if_oversized(&SmsClient.otp_body/1) == 115
        end)

      refute log =~ "140-byte limit"
    end

    test "with NO hashes configured there is nothing to warn about, whatever the template" do
      :persistent_term.erase({SmsRetriever, :oversize_warned})
      configure(nil, String.duplicate("x", 200) <> " {code}")

      log =
        capture_log([level: :warning], fn ->
          SmsRetriever.warn_if_oversized(&SmsClient.otp_body/1)
        end)

      refute log =~ "140-byte limit"
    end
  end

  describe "hashes/0" do
    test "parses, trims and preserves ORDER — the sideload build first during a rollout" do
      configure("#{@debug_hash}, #{@release_hash}")
      assert SmsRetriever.hashes() == [@debug_hash, @release_hash]

      configure([@release_hash, @debug_hash])
      assert SmsRetriever.hashes() == [@release_hash, @debug_hash]

      configure(nil)
      assert SmsRetriever.hashes() == []
    end
  end
end
