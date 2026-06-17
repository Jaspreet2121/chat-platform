defmodule AuthService.RateLimits do
  @moduledoc """
  Auth rate-limit boundary.

  Redis-backed counters will be added later. Redis must remain temporary state,
  not a source of truth. Helper functions here describe Redis keys and policy
  windows without touching Redis.
  """

  @default_scope "otp_request"

  @policies %{
    "otp_request" => %{limit: 5, window_seconds: 900},
    "otp_verify" => %{limit: 5, window_seconds: 300},
    "token_refresh" => %{limit: 30, window_seconds: 300},
    "logout" => %{limit: 60, window_seconds: 300}
  }

  @type rate_limit_attrs :: map()
  @type result :: {:ok, map()} | {:error, atom()}

  @callback check(rate_limit_attrs()) :: result()
  @callback record_attempt(rate_limit_attrs()) :: result()

  def check(_attrs), do: {:error, :not_implemented}

  def record_attempt(_attrs), do: {:error, :not_implemented}

  def policy_for(scope) do
    Map.get(@policies, normalize_scope(scope), @policies[@default_scope])
  end

  def counter_key(attrs) when is_map(attrs) do
    scope = attrs |> get_attr(:scope) |> normalize_scope()
    identifier = attrs |> get_attr(:identifier) |> normalize_identifier()
    identifier_hash = :crypto.hash(:sha256, identifier) |> Base.encode16(case: :lower)

    "auth:rate_limit:#{scope}:#{identifier_hash}"
  end

  def attempt_plan(attrs) when is_map(attrs) do
    scope = attrs |> get_attr(:scope) |> normalize_scope()
    policy = policy_for(scope)

    %{
      key: counter_key(Map.put(attrs, :scope, scope)),
      scope: scope,
      limit: policy.limit,
      window_seconds: policy.window_seconds,
      identifier: normalize_identifier(get_attr(attrs, :identifier)),
      metadata: get_attr(attrs, :metadata) || %{}
    }
  end

  defp normalize_scope(nil), do: @default_scope

  defp normalize_scope(scope) do
    scope
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_identifier(nil), do: "unknown"

  defp normalize_identifier(identifier) do
    identifier
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp get_attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end
end
