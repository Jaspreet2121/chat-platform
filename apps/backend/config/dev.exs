import Config

postgres_connection_config =
  case System.get_env("DATABASE_URL") do
    nil ->
      [
        username: System.get_env("POSTGRES_USER") || "chat_user",
        password: System.get_env("POSTGRES_PASSWORD") || "chat_password",
        hostname: System.get_env("POSTGRES_HOST") || "localhost",
        port: String.to_integer(System.get_env("POSTGRES_PORT") || "5432"),
        database: System.get_env("POSTGRES_DATABASE") || "chat_platform"
      ]

    database_url ->
      [url: database_url]
  end

postgres_config =
  postgres_connection_config ++
    [
      pool_size: String.to_integer(System.get_env("POSTGRES_POOL_SIZE") || "10"),
      stacktrace: true,
      show_sensitive_data_on_connection_error: false
    ]

config :auth_service, AuthService.Repo, postgres_config
config :user_service, UserService.Repo, postgres_config
config :conversation_service, ConversationService.Repo, postgres_config
config :message_service, MessageService.Repo, postgres_config
config :notification_service, NotificationService.Repo, postgres_config
config :media_service, MediaService.Repo, postgres_config

config :api_gateway, ApiGatewayWeb.Endpoint,
  http: [
    ip: {127, 0, 0, 1},
    port: String.to_integer(System.get_env("API_GATEWAY_PORT") || "4000")
  ],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base:
    System.get_env("SECRET_KEY_BASE") ||
      "development-placeholder-change-before-production-development-placeholder",
  server: true
