defmodule AuthService.SmsRetriever do
  @moduledoc """
  The Android SMS Retriever decoration on the OTP text: a `<#>` prefix and the app hashes.

  ## Why the retriever did not fire

  Measured on a real SIM (2026-09-19): the delivered body was the approved wording and nothing else.
  Android logged "No matching message is found" because the API matches on TWO structural markers
  the message did not carry — it begins with `<#>`, and it ends with the 11-character hash of the
  APK that is listening. Wording alone is never enough; the parser never sees a message that lacks
  them.

  ## The shape

      <#> Your Growblic Chat OTP: 123456 Valid for 5 min. Do not share. Growblic Private Limited

      <hash 1>
      <hash 2>

  EVERY configured hash goes on its OWN LINE after ONE blank line. Android matches if ANY line is
  its hash, so one message serves the sideloaded build and the Play build at the same time — which
  is what makes a rollout possible without a second SMS template. The hash is derived from the
  SIGNING CERTIFICATE, so the same source APK signed two ways has two hashes; Play App Signing adds
  a third, from Google's own cert. That is why this is configuration and not a constant.

  ## It can never cost a login

  Absent or empty config renders today's body, byte-identical. A malformed entry is skipped. Nothing
  here raises, and nothing here decides whether the send happens — the decoration is applied to a
  string that is already built.

  ## Length

  The retriever ignores a message over 140 bytes, and a body over 140 bytes also splits into two
  GSM-7 segments: double cost, and the retriever then matches nothing at all. That is a
  configuration mistake nobody would see in a log line about one send, so it is checked ONCE at
  boot, against a representative body, and warned about loudly.
  """

  require Logger

  # The retriever's own limit. Not a guess: the API documents it, and a split message is never
  # matched because each segment arrives as its own SMS.
  @max_bytes 140

  # A stand-in for the real code when measuring at boot — the length is what matters, and a real
  # code must never be minted for a log line.
  @sample_code "000000"

  @warn_key {__MODULE__, :oversize_warned}

  @doc "The configured app hashes, in order. `[]` when unset — the plain body is then used."
  @spec hashes() :: [String.t()]
  def hashes do
    :auth_service
    |> Application.get_env(:sms, [])
    |> Keyword.get(:retriever_app_hashes)
    |> parse()
  end

  # Accepts the raw comma-separated env string OR an already-split list, so the config may be
  # normalised in runtime.exs later without touching this.
  defp parse(value) when is_binary(value), do: value |> String.split(",") |> parse()

  defp parse(values) when is_list(values) do
    values
    |> Enum.map(&(&1 |> to_string() |> String.trim()))
    |> Enum.reject(&(&1 == ""))
  end

  defp parse(_value), do: []

  @doc """
  Decorate an already-rendered OTP body for the retriever. With no configured hashes the body is
  returned UNCHANGED — that is the fallback, and it is the same string that ships today.
  """
  @spec decorate(String.t()) :: String.t()
  def decorate(body), do: decorate(body, hashes())

  @doc "Decoration against an explicit hash list (the tests' entry point)."
  @spec decorate(String.t(), [String.t()]) :: String.t()
  def decorate(body, []), do: to_string(body)

  def decorate(body, hashes) when is_list(hashes) do
    "<#> " <> to_string(body) <> "\n\n" <> Enum.join(hashes, "\n")
  end

  def decorate(body, _hashes), do: to_string(body)

  @doc "The retriever's message-size ceiling, in bytes."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  Warn ONCE, at boot, if the configured hashes would push a representative body past #{@max_bytes}
  bytes. `renderer` builds the undecorated body from a code — passed in so this module never reaches
  back into the SMS client and create a cycle. Returns the measured size.
  """
  @spec warn_if_oversized((String.t() -> String.t())) :: non_neg_integer()
  def warn_if_oversized(renderer) when is_function(renderer, 1) do
    configured = hashes()
    size = configured |> then(&decorate(renderer.(@sample_code), &1)) |> byte_size()

    if configured != [] and size > @max_bytes and
         :persistent_term.get(@warn_key, false) == false do
      :persistent_term.put(@warn_key, true)

      Logger.warning(
        "OTP SMS body is #{size} bytes with #{length(configured)} SMS Retriever hash(es) — over " <>
          "the #{@max_bytes}-byte limit. The message will SPLIT (double cost) and the retriever " <>
          "will never match it. Shorten SMS_OTP_TEMPLATE or configure fewer hashes."
      )
    end

    size
  rescue
    # A boot-time diagnostic must never take the node down.
    _ -> 0
  end
end
