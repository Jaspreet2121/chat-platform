defmodule AuthService.MixProject do
  use Mix.Project

  def project do
    [
      app: :auth_service,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {AuthService.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      # Implements the SharedInfra.AuthClient behaviour (AuthService.AuthClientInProcess).
      # No cycle: shared_infra does not depend on auth_service.
      {:shared_infra, in_umbrella: true},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, ">= 0.0.0"},
      # Outbound HTTP for AuthService.SmsClient (SMSGatewayHub OTP send). NOT SharedInfra.HttpClient
      # — that injects internal headers + decodes our result-envelope; a 3rd-party API needs raw Req.
      {:req, "~> 0.5"},
      # Internal HTTP API (Plug, not Phoenix). The listener is flag-gated/default-off.
      {:plug, "~> 1.14"},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end
