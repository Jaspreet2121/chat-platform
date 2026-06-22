import Config

# Runtime config — evaluated at BOOT (in a release) / after compile (in mix). Only the :prod
# branch runs in production; dev/test are untouched (they keep their compile-time placeholders),
# so plain `mix test` is unaffected. In :prod we FAIL FAST on missing/insecure secrets via
# SharedInfra.ProdConfig rather than booting silently insecure.
if config_env() == :prod do
  # --- Fail-fast on missing / known-insecure-placeholder secrets ---------------------------
  database_url = SharedInfra.ProdConfig.require_present!("DATABASE_URL")
  secret_key_base = SharedInfra.ProdConfig.require_secret!("SECRET_KEY_BASE")
  token_secret = SharedInfra.ProdConfig.require_secret!("TOKEN_SECRET")
  otp_secret = SharedInfra.ProdConfig.require_secret!("OTP_SECRET")

  # --- Repos (all five services share the one managed Postgres for the first deploy) --------
  pool_size = String.to_integer(System.get_env("POOL_SIZE") || "10")
  ssl_enabled = System.get_env("DATABASE_SSL", "true") in ["true", "1", "yes"]
  # verify_none is the pragmatic first-deploy default for managed PG; harden with CA certs later.
  ssl_opts = if ssl_enabled, do: [ssl: true, ssl_opts: [verify: :verify_none]], else: []
  repo_opts = [url: database_url, pool_size: pool_size] ++ ssl_opts

  config :auth_service, AuthService.Repo, repo_opts
  config :user_service, UserService.Repo, repo_opts
  config :conversation_service, ConversationService.Repo, repo_opts
  config :message_service, MessageService.Repo, repo_opts
  config :notification_service, NotificationService.Repo, repo_opts

  # --- Authoritative secrets (override the code's insecure dev fallbacks) -------------------
  config :auth_service, token_secret: token_secret, otp_secret: otp_secret

  # --- API gateway endpoint (serves at runtime in a release) --------------------------------
  host = SharedInfra.ProdConfig.require_present!("PHX_HOST")
  port = String.to_integer(System.get_env("PORT") || "4000")

  check_origin =
    case System.get_env("WEB_ORIGIN") do
      origin when is_binary(origin) and origin != "" -> String.split(origin, ",", trim: true)
      # No explicit allow-list yet → disable the origin check (first-deploy convenience; set
      # WEB_ORIGIN to the web app's URL(s) to lock the websocket down).
      _ -> false
    end

  config :api_gateway, ApiGatewayWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    check_origin: check_origin,
    server: true

  # --- Internal service-to-service HTTP APIs (microservices split) --------------------------
  # When any internal HTTP API is enabled, an INTERNAL_API_TOKEN must be set (TokenPlug fails
  # closed otherwise). Bind these listeners on a PRIVATE network in deployment.
  if System.get_env("INTERNAL_API_TOKEN") do
    config :shared_infra, internal_api_token: System.get_env("INTERNAL_API_TOKEN")
  end

  if port = System.get_env("AUTH_HTTP_PORT") do
    config :auth_service, http_port: String.to_integer(port)
  end

  if port = System.get_env("CONVERSATION_HTTP_PORT") do
    config :conversation_service, http_port: String.to_integer(port)
  end

  if port = System.get_env("USER_HTTP_PORT") do
    config :user_service, http_port: String.to_integer(port)
  end

  if port = System.get_env("MESSAGE_HTTP_PORT") do
    config :message_service, http_port: String.to_integer(port)
  end

  # --- Kafka brokers (only if provided; Kafka stays OFF on the first deploy via its flags) ---
  if brokers = System.get_env("KAFKA_BROKERS") do
    config :message_service, :kafka, brokers: brokers, client_id: "message-service"
    config :conversation_service, :kafka, brokers: brokers, client_id: "conversation-service"
    config :notification_service, :kafka, brokers: brokers, client_id: "notification-service"
    config :realtime_gateway, :kafka, brokers: brokers, client_id: "realtime-gateway"
  end
end
