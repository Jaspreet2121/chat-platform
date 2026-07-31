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
      # :ssl is retained for TLS (e.g. postgrex / Req's Mint transport over https). The
      # service→service HTTP client is now Req (Finch/Mint) in SharedInfra.HttpClient — no longer
      # OTP :httpc, so :inets is no longer needed. :req is declared here so it starts with the app
      # and its default Finch pool supervisor (Req.FinchSupervisor) is available before any call
      # (CI's per-app test boot otherwise left :req unstarted → :noproc on the Finch pool).
      extra_applications: [:logger, :ssl, :req]
    ]
  end

  defp deps do
    [
      {:brod, "~> 4.0"},
      {:jason, "~> 1.4"},
      # HTTP client for the service→service HTTP adapters (SharedInfra.HttpClient). Replaces OTP
      # :httpc, whose inets ships :http_util inconsistently across builds (a fresh CI runner's
      # OTP 27.3 inets had http_util_which=:non_existing → :httpc raised). :req auto-starts its
      # Finch pool when the app boots — no supervision-tree change.
      {:req, "~> 0.5"},
      # For SharedInfra.InternalApi.TokenPlug (internal service-to-service auth plug).
      {:plug, "~> 1.14"},
      # For SharedInfra.Release.load_schema/0 — runs the raw SQL schema against DATABASE_URL from
      # within the release (the slim image has no psql). Already in the tree via ecto_sql.
      {:postgrex, "~> 0.17"},
      # The real CQL driver behind SharedInfra.Scylla.Client (Phase B). Lives HERE because the client
      # boundary does; message_service is the only consumer today. Speaks CQL protocol v4, which
      # Scylla 6.2 serves. NOTE: adding the dep does NOT start anything — the cluster is a supervised
      # child that message_service starts only when SCYLLA_NODES is configured.
      {:xandra, "~> 0.19"},
      # Same override as the umbrella root's, repeated HERE so a per-app run (`cd apps/shared_infra &&
      # mix test`) resolves too — a standalone app project does not inherit the root's overrides.
      # Rationale + safety boundary: see the root mix.exs.
      {:decimal, "~> 3.0", override: true}
    ]
  end
end
