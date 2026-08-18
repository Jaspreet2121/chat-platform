defmodule UserService.MixProject do
  use Mix.Project

  def project do
    [
      app: :user_service,
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
      mod: {UserService.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      # Implements the SharedInfra.UserClient behaviour (UserService.UserClientInProcess).
      # No cycle: shared_infra does not depend on user_service.
      {:shared_infra, in_umbrella: true},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, ">= 0.0.0"},
      # Internal HTTP API (Plug, not Phoenix). The listener is flag-gated/default-off.
      {:plug, "~> 1.14"},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      # UPI payment QR (100): eqrcode renders the PNG; req PUTs it to the media store's presigned URL.
      {:eqrcode, "~> 0.2"},
      {:req, "~> 0.6"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end
