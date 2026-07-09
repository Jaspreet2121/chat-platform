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
    [
      # Implements the SharedInfra.MediaClient behaviour (MediaService.MediaClientInProcess).
      # No cycle: shared_infra does not depend on media_service.
      {:shared_infra, in_umbrella: true},
      # Persists media_assets rows (tenant + ownership) via MediaService.Repo on the shared Postgres.
      {:ecto_sql, "~> 3.10"},
      {:postgrex, "~> 0.17"},
      # Internal HTTP API (Plug, not Phoenix). The listener is flag-gated/default-off.
      {:plug, "~> 1.14"},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"}
    ]
  end
end
