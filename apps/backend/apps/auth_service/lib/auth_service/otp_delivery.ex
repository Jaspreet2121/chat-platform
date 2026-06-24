defmodule AuthService.OtpDelivery do
  @moduledoc """
  Routes a freshly-created OTP to its delivery channel(s).

  Two INDEPENDENT mechanisms:

    * SMS via `AuthService.SmsClient` (SMSGatewayHub), gated by `OTP_SMS_DELIVERY_ENABLED` — the
      production channel. Default OFF.
    * `OTP_DELIVERY_MODE` (default `"none"`) — a LOCAL/STAGING convenience to obtain the code WITHOUT
      SMS: `"echo"` returns the plaintext code in the OTP-request response (`debug_code`); `"log"`
      logs it; `"none"` surfaces nothing (prod-safe default).

  So a local demo = SMS off + `OTP_DELIVERY_MODE=echo`. Default config (neither set) is unchanged:
  hashed, never surfaced.

  RESILIENCE: an SMS failure is LOGGED but does NOT fail OTP creation (the code is persisted; the user
  can resend). SAFETY: `echo`/`log` are LOCAL/STAGING ONLY — if `MIX_ENV=:prod` with one of them set,
  a prominent `Logger.error` fires (plaintext OTP exposure is acceptable for private staging only,
  NEVER real users). Production must use `"none"` + real SMS.
  """

  require Logger

  @compiled_env Mix.env()
  @unsafe_modes ["echo", "log"]
  @warn_key {__MODULE__, :unsafe_prod_warned}

  @doc """
  Side-effect delivery for a freshly-created OTP: SMS (when enabled) + the `log` mode. Always `:ok`.
  `echo` is handled separately by `echo_code/2` (it augments the response).
  """
  @spec deliver(String.t(), String.t(), String.t()) :: :ok
  def deliver(destination, code, method) do
    warn_if_unsafe_in_prod()

    if method == "sms" and sms_enabled?(), do: send_sms(destination, code)

    if delivery_mode() == "log" do
      Logger.warning(
        "OTP debug code (OTP_DELIVERY_MODE=log; LOCAL/STAGING ONLY) for #{destination}: #{code}"
      )
    end

    :ok
  end

  @doc """
  In `echo` mode, inject the plaintext `code` into the OTP-request `response` as `:debug_code` (for
  local frontend testing — visible in the browser network response). Otherwise the response is
  returned unchanged. Prod-safe default (`"none"` → unchanged).
  """
  @spec echo_code(map(), String.t()) :: map()
  def echo_code(response, code) when is_map(response) do
    if delivery_mode() == "echo", do: Map.put(response, :debug_code, code), else: response
  end

  @doc "The configured OTP delivery mode (\"none\" | \"echo\" | \"log\")."
  @spec delivery_mode() :: String.t()
  def delivery_mode, do: Application.get_env(:auth_service, :otp_delivery_mode, "none")

  defp send_sms(destination, code) do
    case AuthService.SmsClient.send_otp(destination, code) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "OTP SMS delivery FAILED (code persisted; user can resend): #{inspect(reason)}"
        )

        :ok
    end
  end

  defp sms_enabled?, do: Application.get_env(:auth_service, :sms, [])[:enabled] == true

  # LOUD guard: plaintext OTP exposure must never be on for real users. Warn once per VM (not a crash).
  defp warn_if_unsafe_in_prod do
    if @compiled_env == :prod and delivery_mode() in @unsafe_modes and
         :persistent_term.get(@warn_key, false) == false do
      :persistent_term.put(@warn_key, true)

      Logger.error(
        "SECURITY: OTP_DELIVERY_MODE=#{delivery_mode()} is exposing PLAINTEXT OTP codes in :prod. " <>
          "Acceptable for PRIVATE STAGING ONLY — NEVER for real users. " <>
          "Set OTP_DELIVERY_MODE=none and use real SMS in production."
      )
    end
  end
end
