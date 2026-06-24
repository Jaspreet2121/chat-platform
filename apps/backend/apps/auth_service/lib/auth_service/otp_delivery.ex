defmodule AuthService.OtpDelivery do
  @moduledoc """
  Routes a freshly-created OTP to its delivery channel.

  SMS via `AuthService.SmsClient` (SMSGatewayHub) when enabled (`OTP_SMS_DELIVERY_ENABLED`) — default
  OFF, so plain `mix test` and existing flows never call out. Email is a separate future channel
  (no-op here).

  RESILIENCE: a delivery failure is LOGGED loudly but does NOT fail OTP creation — the code is already
  persisted, so the user can resend. (Fire-and-forget semantics, mirroring the Kafka producers.)
  """

  require Logger

  @doc "Deliver `code` to `destination` over `delivery_method` (\"sms\" | \"email\"). Always :ok."
  @spec deliver(String.t(), String.t(), String.t()) :: :ok
  def deliver(destination, code, "sms") do
    if sms_enabled?() do
      case AuthService.SmsClient.send_otp(destination, code) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "OTP SMS delivery FAILED (code persisted; user can resend): #{inspect(reason)}"
          )

          :ok
      end
    else
      :ok
    end
  end

  def deliver(_destination, _code, "email"), do: :ok
  def deliver(_destination, _code, _method), do: :ok

  defp sms_enabled?, do: Application.get_env(:auth_service, :sms, [])[:enabled] == true
end
