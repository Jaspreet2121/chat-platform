import Config

# --- Auth OTP delivery config (ALL envs) ----------------------------------------------------------
# MUST be here (not config.exs): config.exs is compile-time for a release, so it would bake the
# BUILD-time env (mode "none", api_key nil, enabled false) and ignore the running container's env.
# runtime.exs is evaluated at BOOT, so the release (and dev/test) read the actual env. Tests still
# override via Application.put_env after boot. DEFAULT "none" keeps prod safe (no plaintext OTP).
config :auth_service, otp_delivery_mode: System.get_env("OTP_DELIVERY_MODE") || "none"

# OTP SMS delivery via SMSGatewayHub (DLT). DEFAULT OFF. api_key/entity_id/template_login_id/route
# are secrets: env only, never committed. Keys match AuthService.SmsClient exactly.
config :auth_service, :sms,
  enabled: System.get_env("OTP_SMS_DELIVERY_ENABLED") in ["true", "1", "yes"],
  base_url: System.get_env("SMS_GATEWAY_HUB_BASE_URL") || "https://www.smsgatewayhub.com",
  send_path: System.get_env("SMS_GATEWAY_HUB_SEND_PATH") || "/api/mt/SendSMS",
  api_key: System.get_env("SMS_GATEWAY_HUB_API_KEY"),
  senderid: System.get_env("SMS_GATEWAY_HUB_SENDER_ID") || "ISOOBC",
  channel: System.get_env("SMS_GATEWAY_HUB_CHANNEL") || "2",
  dcs: System.get_env("SMS_GATEWAY_HUB_DCS") || "0",
  flashsms: System.get_env("SMS_GATEWAY_HUB_FLASHSMS") || "0",
  route: System.get_env("SMS_GATEWAY_HUB_ROUTE"),
  entity_id: System.get_env("SMS_ENTITY_ID"),
  template_login_id: System.get_env("SMS_TEMPLATE_LOGIN_ID"),
  country_prefix: System.get_env("SMS_COUNTRY_PREFIX") || "91"

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

  # Flip a client to its HTTP adapter (calls another service over the network). Default stays
  # in-process. Each needs the target service's base URL.
  if System.get_env("AUTH_CLIENT_ADAPTER") == "http" do
    config :shared_infra, auth_client_adapter: SharedInfra.AuthClientHttp
  end

  if url = System.get_env("AUTH_SERVICE_URL") do
    config :shared_infra, auth_service_url: url
  end

  if System.get_env("CONVERSATION_CLIENT_ADAPTER") == "http" do
    config :shared_infra, conversation_client_adapter: SharedInfra.ConversationClientHttp
  end

  if url = System.get_env("CONVERSATION_SERVICE_URL") do
    config :shared_infra, conversation_service_url: url
  end

  if System.get_env("USER_CLIENT_ADAPTER") == "http" do
    config :shared_infra, user_client_adapter: SharedInfra.UserClientHttp
  end

  if url = System.get_env("USER_SERVICE_URL") do
    config :shared_infra, user_service_url: url
  end

  if System.get_env("MESSAGE_CLIENT_ADAPTER") == "http" do
    config :shared_infra, message_client_adapter: SharedInfra.MessageClientHttp
  end

  if url = System.get_env("MESSAGE_SERVICE_URL") do
    config :shared_infra, message_service_url: url
  end

  # Message store backend — selected at RUNTIME. config.exs picks the adapter at COMPILE time, so a
  # release bakes the build-time default (MESSAGE_STORE_ADAPTER unset → QueryPlanAdapter, which is the
  # "unavailable" placeholder) and ignores the container's MESSAGE_STORE_ADAPTER env → message
  # send/list fail with :message_store_unavailable (surfaced as 400 at the gateway). Read it at boot
  # here, same as the client-adapter flips above. Only overrides when the env is set, so dev/test keep
  # their compile-time default (Docker-free `mix test` unaffected). See DECISION_LOG [2026-06-24].
  if adapter = System.get_env("MESSAGE_STORE_ADAPTER") do
    config :message_service,
      message_store_adapter:
        (case adapter do
           "scylla" -> MessageService.MessageStore.ScyllaAdapter
           "postgres" -> MessageService.MessageStore.PostgresAdapter
           "in_memory" -> MessageService.MessageStore.InMemoryAdapter
           _ -> MessageService.MessageStore.QueryPlanAdapter
         end)
  end

  if System.get_env("MEDIA_CLIENT_ADAPTER") == "http" do
    config :shared_infra, media_client_adapter: SharedInfra.MediaClientHttp
  end

  if url = System.get_env("MEDIA_SERVICE_URL") do
    config :shared_infra, media_service_url: url
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

  if port = System.get_env("MEDIA_HTTP_PORT") do
    config :media_service, http_port: String.to_integer(port)
  end

  # --- Kafka brokers (only if provided; Kafka stays OFF on the first deploy via its flags) ---
  if brokers = System.get_env("KAFKA_BROKERS") do
    config :message_service, :kafka, brokers: brokers, client_id: "message-service"
    config :conversation_service, :kafka, brokers: brokers, client_id: "conversation-service"
    config :notification_service, :kafka, brokers: brokers, client_id: "notification-service"
    config :realtime_gateway, :kafka, brokers: brokers, client_id: "realtime-gateway"
  end
end
