defmodule NotificationService.MixProject do
  use Mix.Project

  def project do
    [
      app: :notification_service,
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
      mod: {NotificationService.Application, []},
      extra_applications: [:logger, :crypto]
    ]
  end

  defp deps do
    [
      {:shared_infra, in_umbrella: true},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, ">= 0.0.0"},
      {:brod, "~> 4.0"},
      {:jason, "~> 1.4"},
      # VAPID web-push (RFC 8291 encryption + RFC 8292 signing) — the sender leg for message pushes.
      {:web_push_encryption, "~> 0.3"},
      # FCM leg (Phase 2, Android): :req for the HTTP v1 send + the OAuth token exchange, :jose to
      # sign the service-account JWT assertion. Both were ALREADY in the lockfile (:req across the
      # umbrella, :jose via web_push_encryption) — declared here because this app now uses them
      # directly. Deliberately NOT `goth`: one signed assertion an hour needs no supervision tree.
      {:req, "~> 0.5"},
      {:jose, "~> 1.11"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end
