defmodule SharedInfra.MixProject do
  use Mix.Project

  def project do
    [
      app: :shared_infra,
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
      # :inets/:ssl provide :httpc, the HTTP client used by SharedInfra.HttpClient for the
      # service→service HTTP adapters. Zero new deps (ships with OTP); isolated behind the
      # helper so it can be swapped for Req when a package registry is reachable.
      extra_applications: [:logger, :inets, :ssl]
    ]
  end

  defp deps do
    [
      {:brod, "~> 4.0"},
      {:jason, "~> 1.4"},
      # For SharedInfra.InternalApi.TokenPlug (internal service-to-service auth plug).
      {:plug, "~> 1.14"}
    ]
  end
end
