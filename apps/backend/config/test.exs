import Config

get_env =
  fn keys, default ->
    Enum.find_value(keys, &System.get_env/1) || default
  end

postgres_connection_config =
  case System.get_env("TEST_DATABASE_URL") do
    nil ->
      [
        username: get_env.(["POSTGRES_TEST_USER", "POSTGRES_USER"], "chat_user"),
        password: get_env.(["POSTGRES_TEST_PASSWORD", "POSTGRES_PASSWORD"], "chat_password"),
        hostname: get_env.(["POSTGRES_TEST_HOST", "POSTGRES_HOST"], "localhost"),
        port: String.to_integer(get_env.(["POSTGRES_TEST_PORT", "POSTGRES_PORT"], "5432")),
        database: get_env.(["POSTGRES_TEST_DATABASE", "POSTGRES_TEST_DB"], "chat_platform_test")
      ]

    database_url ->
      [url: database_url]
  end

postgres_config =
  postgres_connection_config ++
    [
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: 5,
      show_sensitive_data_on_connection_error: false
    ]

config :auth_service, AuthService.Repo, postgres_config
config :user_service, UserService.Repo, postgres_config
config :conversation_service, ConversationService.Repo, postgres_config
config :message_service, MessageService.Repo, postgres_config
config :notification_service, NotificationService.Repo, postgres_config
config :media_service, MediaService.Repo, postgres_config

# Repos are NOT supervised at boot in :test — DataCase starts them per-test, so plain
# `mix test` stays Docker-free (nothing connects unless a DB-tagged test runs).
config :auth_service, start_repo: false
config :user_service, start_repo: false
config :conversation_service, start_repo: false
config :message_service, start_repo: false
config :notification_service, start_repo: false

config :api_gateway, ApiGatewayWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base:
    System.get_env("SECRET_KEY_BASE") ||
      "test-placeholder-change-before-production-test-placeholder-value",
  server: false

config :shared_infra,
  rate_limiter_adapter: SharedInfra.RateLimiter.InMemoryAdapter,
  rate_limiter_fail_open: true

# The /socket connection counter uses in-process ETS in tests (deterministic, no Redis). Prod defaults to
# :redis (multi-node); RT_RUNTIME_BACKEND overrides either way — see RealtimeGateway.ConnectionCounter.
config :realtime_gateway, connection_counter_backend: :ets

config :media_service,
  media_storage_adapter: MediaService.Storage.QueryPlanAdapter

# The inbox recount/reconcile SQL reads the Postgres `messages` table directly, so it is only correct
# while Postgres is the authoritative store — `ConversationService.InboxCounters` refuses to run
# otherwise, and treats an UNKNOWN backend as "not Postgres" (see its moduledoc). The inbox tests seed
# and assert against Postgres `messages`, so for them Postgres genuinely IS the store. Stated here
# rather than defaulted in code: the whole point of the interlock is that it must be declared, and a
# test that silently no-ops would prove nothing while looking green.
config :shared_infra, message_store_backend: "postgres"
