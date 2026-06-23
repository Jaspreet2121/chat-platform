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

  # Releases. Boot config (DATABASE_URL, secrets, host) is read at runtime in config/runtime.exs.
  #
  # `chat_platform` — the all-in-one umbrella release (single-container baseline).
  #
  # Per-service releases — each bundles ONLY its own app + shared_infra (+ hex deps), NOT the
  # other services. This is the container-split payoff: `mix release auth_service` produces an
  # image that boots auth_service standalone. shared_infra is included because the service
  # depends on it (Kafka/Redis/Scylla helpers + the *Client dispatchers). No runtime behavior
  # change — these are packaging definitions only; which adapter resolves is still config-driven.
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
      ],
      auth_service: [
        version: "0.1.0",
        applications: [shared_infra: :permanent, auth_service: :permanent]
      ],
      user_service: [
        version: "0.1.0",
        applications: [shared_infra: :permanent, user_service: :permanent]
      ],
      conversation_service: [
        version: "0.1.0",
        applications: [shared_infra: :permanent, conversation_service: :permanent]
      ],
      message_service: [
        version: "0.1.0",
        applications: [shared_infra: :permanent, message_service: :permanent]
      ],
      media_service: [
        version: "0.1.0",
        applications: [shared_infra: :permanent, media_service: :permanent]
      ],
      gateway: [
        version: "0.1.0",
        applications: [
          shared_infra: :permanent,
          realtime_gateway: :permanent,
          api_gateway: :permanent
        ]
      ]
    ]
  end
end
