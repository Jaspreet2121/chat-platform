defmodule AuthService.SMS do
  @moduledoc """
  Provider-agnostic OTP SMS front door. `send_otp/2` dispatches on the configured provider so the
  concrete gateway is one swappable adapter behind this interface:

    * `"console"` (DEFAULT) — local/dev: logs the code (NON-prod only) and sends NO real SMS. No credits
      burned, no DLT needed. In `:prod` it logs a ONE-TIME misconfiguration warning WITHOUT the code
      (OTP codes are never logged in prod) — production must set `SMS_PROVIDER=smsgatewayhub`.
    * `"smsgatewayhub"` — real DLT/TRAI-compliant send via `AuthService.SmsClient`.

  Provider resolves from `SMS_PROVIDER` (config `:auth_service, :sms, :provider`). When that is unset it
  falls back to the LEGACY `OTP_SMS_DELIVERY_ENABLED` flag (`true` → smsgatewayhub, else console) so
  existing deployments keep working; `SMS_PROVIDER` supersedes the flag. Adding a provider later = one
  more clause here + its adapter. Always returns `:ok | {:error, reason}`; never raises.
  """

  require Logger

  @compiled_env Mix.env()
  @warn_key {__MODULE__, :prod_console_warned}

  @doc "Send the OTP `code` to `number` via the configured provider. `:ok` on success, else `{:error, _}`."
  @spec send_otp(String.t(), String.t()) :: :ok | {:error, term()}
  def send_otp(number, code) do
    case provider() do
      "smsgatewayhub" -> AuthService.SmsClient.send_otp(number, code)
      "console" -> console(number, code)
      other -> {:error, {:unknown_sms_provider, other}}
    end
  end

  @doc """
  The resolved provider name (`"console"` | `"smsgatewayhub"`), honoring `SMS_PROVIDER` then the legacy
  `OTP_SMS_DELIVERY_ENABLED` flag.
  """
  @spec provider() :: String.t()
  def provider do
    case Application.get_env(:auth_service, :sms, [])[:provider] do
      value when is_binary(value) and value != "" -> value
      _ -> if legacy_enabled?(), do: "smsgatewayhub", else: "console"
    end
  end

  defp legacy_enabled?, do: Application.get_env(:auth_service, :sms, [])[:enabled] == true

  # Console adapter: dev prints the code (so local login works with zero SMS setup); prod NEVER logs the
  # code — a console provider in prod means SMS is unconfigured, so warn loudly once and drop the send.
  defp console(number, code) do
    if @compiled_env == :prod do
      if :persistent_term.get(@warn_key, false) == false do
        :persistent_term.put(@warn_key, true)

        Logger.error(
          "SMS_PROVIDER=console in :prod — OTP NOT delivered (no SMS provider configured). " <>
            "Set SMS_PROVIDER=smsgatewayhub + credentials to send real texts."
        )
      end
    else
      Logger.info("[SMS console] OTP for #{number}: #{code}  (dev only — no real SMS sent)")
    end

    :ok
  end
end
