defmodule AuthService.ReviewerLogins do
  @moduledoc """
  Play-reviewer test logins (2026-08-18): a config-driven allowlist of phone numbers whose OTP is a
  FIXED code and whose request never touches the SMS provider — so Google's reviewers can sign in
  without receiving a text. Everything else about their login is a NORMAL login: same response
  shape, same rate limits, same verification-code row + attempts cap, same session, same tenant.

  Config: env `REVIEWER_TEST_LOGINS` = comma-separated `<E.164 phone>:<6-digit code>` entries
  (empty/unset = feature OFF — the default everywhere). Parsed once at boot (`load/0`, runtime env
  read — never config.exs-baked); only the COUNT is ever logged, never the values. Rotation =
  change the env, restart the auth service.

  Not an enumeration oracle: request-otp for an allowlisted number is byte-identical to a normal
  request (a real verification-code row is still created; only the provider send is skipped), and
  verify still charges attempts. The code compare is constant-time.
  """

  require Logger

  @app :auth_service
  @key :reviewer_test_logins

  @doc "Parse REVIEWER_TEST_LOGINS at boot into app env. Logs the count only."
  def load do
    {entries, dropped} = parse(System.get_env("REVIEWER_TEST_LOGINS") || "")
    Application.put_env(@app, @key, entries)

    if map_size(entries) > 0,
      do: Logger.info("reviewer test logins: #{map_size(entries)} configured")

    if dropped > 0,
      do: Logger.warning("reviewer test logins: #{dropped} malformed entries DROPPED")

    :ok
  end

  @doc "Is this destination an allowlisted reviewer number? (false whenever the feature is off)"
  def allowlisted?(destination) when is_binary(destination),
    do: Map.has_key?(entries(), destination)

  def allowlisted?(_), do: false

  @doc "Constant-time check of the presented code against the configured one for this number."
  def code_matches?(destination, presented)
      when is_binary(destination) and is_binary(presented) do
    case Map.get(entries(), destination) do
      code when is_binary(code) and byte_size(code) == byte_size(presented) ->
        :crypto.hash_equals(code, presented)

      _ ->
        false
    end
  end

  def code_matches?(_destination, _presented), do: false

  @doc "Masked form for audit logs: last 4 digits only."
  def mask(destination) when is_binary(destination),
    do: "…" <> String.slice(destination, -4, 4)

  def mask(_), do: "…"

  defp entries, do: Application.get_env(@app, @key, %{})

  # "<+phone>:<6 digits>[,<+phone>:<6 digits>...]" — malformed entries are dropped (counted, never
  # printed). The phone must look E.164-ish; the code must be exactly 6 digits.
  defp parse(raw) do
    raw
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reduce({%{}, 0}, fn entry, {acc, dropped} ->
      case String.split(entry, ":", parts: 2) do
        [phone, code] ->
          if valid_phone?(phone) and valid_code?(code) do
            {Map.put(acc, phone, code), dropped}
          else
            {acc, dropped + 1}
          end

        _ ->
          {acc, dropped + 1}
      end
    end)
  end

  defp valid_phone?(phone), do: Regex.match?(~r/^\+?[0-9]{8,15}$/, phone)
  defp valid_code?(code), do: Regex.match?(~r/^[0-9]{6}$/, code)
end
