defmodule ChatPlatform.Backend.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  defp deps do
    []
  end

  # Umbrella release: bundles all apps so `MIX_ENV=prod mix release` produces a runnable
  # server. Boot config (DATABASE_URL, secrets, host) is read at runtime in config/runtime.exs.
  defp releases do
    [
      chat_platform: [
        version: "0.1.0",
        applications: [
          shared_infra: :permanent,
          auth_service: :permanent,
          user_service: :permanent,
          conversation_service: :permanent,
          message_service: :permanent,
          notification_service: :permanent,
          media_service: :permanent,
          realtime_gateway: :permanent,
          api_gateway: :permanent
        ]
      ]
    ]
  end
end
