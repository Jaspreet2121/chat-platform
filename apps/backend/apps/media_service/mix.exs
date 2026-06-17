defmodule MediaService.MixProject do
  use Mix.Project

  def project do
    [
      app: :media_service,
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
      mod: {MediaService.Application, []},
      extra_applications: [:logger, :crypto]
    ]
  end

  defp deps do
    []
  end
end
