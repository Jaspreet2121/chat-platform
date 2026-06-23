defmodule SharedInfra.ProdConfig do
  @moduledoc """
  Fail-fast guards for production boot configuration.

  `config/runtime.exs` calls these ONLY when `config_env() == :prod`, so a production
  release REFUSES to boot with missing or known-insecure-placeholder secrets rather than
  silently running with the dev/test defaults baked into the code
  (`*-change-before-production`, `*-placeholder-*`). Pure functions (read env / inspect a
  string) so they are unit-testable without a real prod environment.
  """

  # Any value containing one of these markers is a known insecure default, never valid in prod.
  @placeholder_markers [
    "change-before-production",
    "development-placeholder",
    "test-placeholder"
  ]

  @doc """
  Returns the value of env var `name`, or RAISES if it is unset/blank or equals a known
  insecure placeholder. Use for secrets that must be set to a real value in production.
  """
  @spec require_secret!(String.t()) :: String.t()
  def require_secret!(name) when is_binary(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" ->
        if placeholder?(value) do
          raise "FATAL: #{name} is set to a known insecure placeholder. " <>
                  "Set a real secret before booting production."
        else
          value
        end

      _ ->
        raise "FATAL: #{name} is not set. Refusing to boot production without a secure value."
    end
  end

  @doc """
  Returns the value of required (non-secret) env var `name`, or RAISES if unset/blank.
  Use for things like DATABASE_URL that must be present but aren't secret-placeholder-checked.
  """
  @spec require_present!(String.t()) :: String.t()
  def require_present!(name) when is_binary(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> raise "FATAL: #{name} is not set. Refusing to boot production without it."
    end
  end

  @doc "True if `value` is one of the known insecure dev/test placeholder secrets."
  @spec placeholder?(String.t()) :: boolean()
  def placeholder?(value) when is_binary(value) do
    down = String.downcase(value)
    Enum.any?(@placeholder_markers, &String.contains?(down, &1))
  end

  def placeholder?(_), do: false
end
