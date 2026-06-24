defmodule ApiGateway.MixProject do
  use Mix.Project

  def project do
    [
      app: :api_gateway,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {ApiGateway.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp deps do
    [
      {:realtime_gateway, in_umbrella: true},
      {:shared_infra, in_umbrella: true},
      {:phoenix, "~> 1.7"},
      {:phoenix_pubsub, "~> 2.1"},
      {:plug_cowboy, "~> 2.7"},
      {:cors_plug, "~> 3.0"},
      {:jason, "~> 1.4"}
    ]
  end
end
