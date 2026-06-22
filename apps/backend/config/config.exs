import Config

config :phoenix, :json_library, Jason

config :phoenix, :filter_parameters, [
  "password",
  "token",
  "refresh_token",
  "access_token",
  "otp",
  "otp_code"
]

config :api_gateway, ApiGatewayWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [
    formats: [json: ApiGatewayWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ApiGateway.PubSub

config :api_gateway,
  rate_limiting_enabled: System.get_env("API_RATE_LIMITING_ENABLED") in ["true", "1", "yes"]

config :shared_infra,
  rate_limiter_adapter: SharedInfra.RateLimiter.RedisAdapter,
  rate_limiter_fail_open: System.get_env("RATE_LIMITER_FAIL_OPEN", "true") in ["true", "1", "yes"]

config :shared_infra, :redis,
  url:
    System.get_env("RATE_LIMITER_REDIS_URL") ||
      System.get_env("REDIS_URL") ||
      "redis://localhost:6379/0",
  timeout: String.to_integer(System.get_env("RATE_LIMITER_REDIS_TIMEOUT_MS") || "1000")

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :auth_service, ecto_repos: [AuthService.Repo]

config :auth_service, :tokens,
  access_token_ttl_seconds:
    String.to_integer(System.get_env("AUTH_ACCESS_TOKEN_TTL_SECONDS") || "900"),
  refresh_token_ttl_seconds:
    String.to_integer(System.get_env("AUTH_REFRESH_TOKEN_TTL_SECONDS") || "2592000"),
  issuer: System.get_env("AUTH_TOKEN_ISSUER") || "chat-platform",
  audience: System.get_env("AUTH_TOKEN_AUDIENCE") || "chat-platform-clients"

config :user_service, ecto_repos: [UserService.Repo]
config :conversation_service, ecto_repos: [ConversationService.Repo]
config :message_service, ecto_repos: [MessageService.Repo]
config :notification_service, ecto_repos: [NotificationService.Repo]

config :message_service, :scylla,
  nodes:
    (System.get_env("SCYLLA_CONTACT_POINTS") || "localhost:9042")
    |> String.split(",", trim: true)
    |> Enum.map(fn contact_point ->
      case String.split(contact_point, ":", parts: 2) do
        [host, port] -> {host, String.to_integer(port)}
        [host] -> {host, 9042}
      end
    end),
  keyspace: System.get_env("SCYLLA_KEYSPACE") || "chat_messages",
  timeout: String.to_integer(System.get_env("SCYLLA_TIMEOUT_MS") || "5000")

config :message_service, :kafka,
  brokers: System.get_env("KAFKA_BROKERS") || "localhost:9094",
  client_id: System.get_env("KAFKA_CLIENT_ID") || "message-service"

config :message_service,
  message_persistence: System.get_env("MESSAGE_DB_BACKED") in ["true", "1", "yes"],
  kafka_publish_enabled: System.get_env("KAFKA_PUBLISH_ENABLED") in ["true", "1", "yes"],
  kafka_consumer_enabled: System.get_env("KAFKA_CONSUMER_ENABLED") in ["true", "1", "yes"],
  kafka_projection_consumer_enabled:
    System.get_env("KAFKA_PROJECTION_CONSUMER_ENABLED") in ["true", "1", "yes"],
  message_store_adapter:
    (case System.get_env("MESSAGE_STORE_ADAPTER") do
       "scylla" -> MessageService.MessageStore.ScyllaAdapter
       "postgres" -> MessageService.MessageStore.PostgresAdapter
       "in_memory" -> MessageService.MessageStore.InMemoryAdapter
       _ -> MessageService.MessageStore.QueryPlanAdapter
     end)

config :notification_service, :kafka,
  brokers: System.get_env("KAFKA_BROKERS") || "localhost:9094",
  client_id: System.get_env("KAFKA_CLIENT_ID") || "notification-service"

# notification-service consumers are OFF by default: with both flags off,
# NotificationService.Application starts no children (no Repo, no Kafka client, no consumer) →
# plain mix test stays Docker-free. The two consumers toggle independently.
config :notification_service,
  consumer_enabled: System.get_env("NOTIFICATION_CONSUMER_ENABLED") in ["true", "1", "yes"],
  participants_consumer_enabled:
    System.get_env("NOTIFICATION_PARTICIPANTS_CONSUMER_ENABLED") in ["true", "1", "yes"]

# Auth client boundary: edge apps call SharedInfra.AuthClient, which dispatches to this adapter.
# Default = in-process (delegates to AuthService.*, zero behavior change). A future HTTP adapter
# (separate auth-service container) is selected by overriding this in runtime config.
config :shared_infra, auth_client_adapter: AuthService.AuthClientInProcess

# Internal service-to-service HTTP APIs (microservices split). The token guards the internal
# APIs (TokenPlug fails closed if unset); nil by default in dev/test. Each service's internal
# HTTP listener is flag-gated (e.g. AUTH_HTTP_API_ENABLED), default off → no listener at boot.
config :shared_infra, internal_api_token: System.get_env("INTERNAL_API_TOKEN")

config :auth_service,
  http_api_enabled: System.get_env("AUTH_HTTP_API_ENABLED") in ["true", "1", "yes"]

config :conversation_service,
  http_api_enabled: System.get_env("CONVERSATION_HTTP_API_ENABLED") in ["true", "1", "yes"]

config :user_service,
  http_api_enabled: System.get_env("USER_HTTP_API_ENABLED") in ["true", "1", "yes"]

config :message_service,
  http_api_enabled: System.get_env("MESSAGE_HTTP_API_ENABLED") in ["true", "1", "yes"]

config :shared_infra, conversation_client_adapter: ConversationService.ConversationClientInProcess
config :shared_infra, user_client_adapter: UserService.UserClientInProcess
config :shared_infra, message_client_adapter: MessageService.MessageClientInProcess
config :shared_infra, media_client_adapter: MediaService.MediaClientInProcess

config :shared_infra,
  scylla_client_adapter: SharedInfra.Scylla.UnavailableClient,
  kafka_producer_adapter:
    (case System.get_env("KAFKA_PRODUCER_ADAPTER") do
       "brod" -> SharedInfra.Kafka.BrodProducer
       _ -> SharedInfra.Kafka.NoopProducer
     end)

config :media_service,
  media_persistence: System.get_env("MEDIA_DB_BACKED") in ["true", "1", "yes"],
  media_storage_adapter:
    (case System.get_env("MEDIA_STORAGE_ADAPTER") do
       "minio" -> MediaService.Storage.MinioAdapter
       "in_memory" -> MediaService.Storage.InMemoryAdapter
       _ -> MediaService.Storage.QueryPlanAdapter
     end)

config :media_service, :minio,
  endpoint: System.get_env("MINIO_ENDPOINT") || "http://localhost:9000",
  bucket: System.get_env("MINIO_BUCKET") || "chat-media",
  access_key_id:
    System.get_env("MINIO_ACCESS_KEY") || System.get_env("MINIO_ACCESS_KEY_ID") || "minioadmin",
  secret_access_key:
    System.get_env("MINIO_SECRET_KEY") || System.get_env("MINIO_SECRET_ACCESS_KEY") ||
      "minioadmin",
  region: System.get_env("MINIO_REGION") || "us-east-1",
  url_expires_seconds: String.to_integer(System.get_env("MINIO_URL_EXPIRES_SECONDS") || "900"),
  path_style: System.get_env("MINIO_PATH_STYLE", "true") in ["true", "1", "yes"]

config :realtime_gateway, :redis, url: System.get_env("REDIS_URL") || "redis://localhost:6379/0"

# Trustworthy realtime socket identity requires BOTH REALTIME_AUTH_DB_BACKED=true AND
# AUTH_SESSION_DB_BACKED=true. Enabling REALTIME_AUTH_DB_BACKED WITHOUT
# AUTH_SESSION_DB_BACKED is a misconfiguration: the socket now FAILS CLOSED (rejects the
# connection) instead of silently accepting an unverified placeholder identity. With the
# flag OFF (local-dev default) the socket trusts a client-provided user_id — never run
# production with it off.
config :realtime_gateway,
  socket_auth_persistence: System.get_env("REALTIME_AUTH_DB_BACKED") in ["true", "1", "yes"]

config :realtime_gateway, :kafka,
  brokers: System.get_env("KAFKA_BROKERS") || "localhost:9094",
  client_id: System.get_env("KAFKA_CLIENT_ID") || "realtime-gateway"

config :user_service,
  user_profile_persistence: System.get_env("USER_PROFILE_DB_BACKED") in ["true", "1", "yes"]

import_config "#{config_env()}.exs"

config :conversation_service, :kafka,
  brokers: System.get_env("KAFKA_BROKERS") || "localhost:9094",
  client_id: System.get_env("KAFKA_CLIENT_ID") || "conversation-service"

config :conversation_service,
  conversation_persistence: System.get_env("CONVERSATION_DB_BACKED") in ["true", "1", "yes"],
  # Producer is OFF by default: with this off (or the default NoopProducer adapter),
  # ConversationService.Application starts no brod client → plain mix test stays Docker-free.
  conversation_publish_enabled:
    System.get_env("CONVERSATION_PUBLISH_ENABLED") in ["true", "1", "yes"]
