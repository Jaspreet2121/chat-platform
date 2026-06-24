defmodule AuthService.SmsClient do
  @moduledoc """
  Outbound OTP SMS via SMSGatewayHub (DLT/TRAI-compliant).

  POSTs to `/api/mt/SendSMS` with QUERY-STRING params (empty body). The `text` MUST exactly match the
  DLT-approved LOGIN template ("Dear user, your login OTP is {#var#} 1500BC", with the code in place
  of `{#var#}`) — any deviation is provider ErrorCode 024. Success = response JSON `ErrorCode=="000"`;
  any other code is a failure (logged with code + message). Transport/timeout → `{:error, :sms_unavailable}`.
  NEVER raises into the caller.

  All config (incl. the secret `api_key`) comes from `config :auth_service, :sms` (env-driven) — nothing
  hardcoded. `req_options` lets tests inject a Req `plug:` stub so the real provider is never called.
  """

  require Logger

  @doc "Send the OTP `code` to `number`. `:ok` on ErrorCode 000, else `{:error, reason}` (logged)."
  @spec send_otp(String.t(), String.t()) :: :ok | {:error, term()}
  def send_otp(number, code) do
    cfg = config()
    url = to_string(cfg[:base_url]) <> to_string(cfg[:send_path])

    params = [
      APIKey: cfg[:api_key],
      senderid: cfg[:senderid],
      channel: cfg[:channel],
      DCS: cfg[:dcs],
      flashsms: cfg[:flashsms],
      number: format_number(number, cfg[:country_prefix] || "91"),
      text: otp_text(code),
      route: cfg[:route],
      EntityId: cfg[:entity_id],
      templateid: cfg[:template_login_id]
    ]

    req = [method: :post, url: url, params: params, receive_timeout: 5_000, retry: false]

    case Req.request(req ++ (cfg[:req_options] || [])) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        interpret(body)

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("SMS send: provider returned HTTP #{status}")
        {:error, {:http_status, status}}

      {:error, reason} ->
        Logger.warning("SMS send: transport failure: #{inspect(reason)}")
        {:error, :sms_unavailable}
    end
  rescue
    error ->
      Logger.warning("SMS send raised: #{inspect(error)}")
      {:error, :sms_unavailable}
  catch
    kind, value ->
      Logger.warning("SMS send #{kind}: #{inspect(value)}")
      {:error, :sms_unavailable}
  end

  @doc "The DLT-approved LOGIN template with `code` substituted for `{#var#}` (must match verbatim)."
  @spec otp_text(String.t()) :: String.t()
  def otp_text(code), do: "Dear user, your login OTP is #{code} 1500BC"

  @doc """
  Bridge a phone to the provider's country-code form: digits only; a bare 10-digit number gets the
  `country_prefix` (default 91). A number that already includes the country code is passed through.
  """
  @spec format_number(String.t(), String.t()) :: String.t()
  def format_number(number, country_prefix) do
    digits = number |> to_string() |> String.replace(~r/\D/, "")
    if String.length(digits) == 10, do: country_prefix <> digits, else: digits
  end

  defp interpret(body) when is_map(body) do
    case body["ErrorCode"] do
      "000" ->
        :ok

      other ->
        Logger.warning(
          "SMS send rejected: ErrorCode=#{inspect(other)} #{inspect(body["ErrorMessage"])}"
        )

        {:error, {other, body["ErrorMessage"]}}
    end
  end

  defp interpret(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} ->
        interpret(map)

      _ ->
        Logger.warning("SMS send: unparseable provider response")
        {:error, :sms_unavailable}
    end
  end

  defp interpret(_), do: {:error, :sms_unavailable}

  defp config, do: Application.get_env(:auth_service, :sms, [])
end
