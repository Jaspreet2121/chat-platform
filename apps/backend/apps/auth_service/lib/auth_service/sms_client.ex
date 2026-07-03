defmodule AuthService.SmsClient do
  @moduledoc """
  Outbound OTP SMS via SMSGatewayHub (DLT/TRAI-compliant).

  GETs `/api/mt/SendSMS` with QUERY-STRING params (method configurable via `SMS_HTTP_METHOD`, default
  `get` — their IIS rejects a bodyless POST with HTTP 411). The `text` MUST exactly match the
  DLT-approved LOGIN template ("Dear user, your login OTP is {#var#} 1500BC", with the code in place
  of `{#var#}`) — any deviation is provider ErrorCode 024. Success = response JSON `ErrorCode=="000"`;
  any other code is a failure (logged with code + message). Transport/timeout → `{:error, :sms_unavailable}`.
  NEVER raises into the caller.

  All config (incl. the secret `api_key`) comes from `config :auth_service, :sms` (env-driven) — nothing
  hardcoded. The message body is a configurable template (`SMS_OTP_TEMPLATE`) with a `{code}` placeholder,
  so it can be edited to match the DLT-approved wording WITHOUT a redeploy; it defaults to the current
  approved LOGIN template. `req_options` lets tests inject a Req `plug:` stub so the real provider is
  never called.
  """

  require Logger

  # Default = the DLT-approved LOGIN template, verbatim, with `{code}` where the OTP is substituted.
  @default_otp_template "Dear user, your login OTP is {code} 1500BC"

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
      number: format_number(number, cfg[:country_prefix] || "91", cfg[:strip_country_code] == true),
      text: otp_text(code),
      route: cfg[:route],
      EntityId: cfg[:entity_id],
      templateid: cfg[:template_login_id]
    ]

    req = [method: http_method(cfg), url: url, params: params, receive_timeout: 5_000, retry: false]

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

  @doc """
  The OTP message body: the configured template (`SMS_OTP_TEMPLATE`, default = the DLT-approved LOGIN
  template) with every `{code}` placeholder replaced by `code`. Must resolve to the DLT-approved wording
  verbatim, or the provider rejects it (ErrorCode 024).
  """
  @spec otp_text(String.t()) :: String.t()
  def otp_text(code) do
    template = config()[:otp_template] || @default_otp_template
    String.replace(to_string(template), "{code}", to_string(code))
  end

  @doc """
  Bridge a phone to the form the provider expects (digits only).

    * default: a bare 10-digit number gets the `country_prefix` (91) prepended; an already-prefixed
      number is passed through → e.g. "919041705621".
    * `strip_country_code?` true (`SMS_STRIP_COUNTRY_CODE`): send the BARE national number — drop a
      leading `country_prefix` when the remainder is 10 digits → e.g. "9041705621". Some DLT/provider
      setups expect the 10-digit number without the country code.
  """
  @spec format_number(String.t(), String.t(), boolean()) :: String.t()
  def format_number(number, country_prefix, strip_country_code? \\ false) do
    digits = number |> to_string() |> String.replace(~r/\D/, "")
    prefix = to_string(country_prefix)

    cond do
      strip_country_code? and String.starts_with?(digits, prefix) and
          String.length(digits) - String.length(prefix) == 10 ->
        String.replace_prefix(digits, prefix, "")

      strip_country_code? ->
        digits

      String.length(digits) == 10 ->
        prefix <> digits

      true ->
        digits
    end
  end

  defp interpret(body) when is_map(body) do
    case body["ErrorCode"] do
      "000" ->
        # Log the provider's correlation ids (NOT the code) so an accepted send can be traced in the
        # SMSGatewayHub delivery report.
        message_id =
          case body["MessageData"] do
            [%{"MessageId" => id} | _] -> id
            _ -> nil
          end

        Logger.info(
          "SMS accepted by provider: JobId=#{inspect(body["JobId"])} MessageId=#{inspect(message_id)}"
        )

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

  # SMSGatewayHub's /api/mt/SendSMS is a query-param API; it must be a GET (a POST with no body is
  # rejected by their IIS with HTTP 411 Length Required). Configurable via SMS_HTTP_METHOD; default :get.
  defp http_method(cfg) do
    case cfg[:http_method] do
      method when is_atom(method) and not is_nil(method) -> method
      method when is_binary(method) -> if String.downcase(method) == "post", do: :post, else: :get
      _ -> :get
    end
  end
end
