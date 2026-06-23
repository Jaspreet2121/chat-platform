defmodule RealtimeGateway.MixProject do
  use Mix.Project

  def project do
    [
      app: :realtime_gateway,
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
      mod: {RealtimeGateway.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:phoenix_pubsub, "~> 2.1"},
      {:shared_infra, in_umbrella: true}
    ]
  end
end
