import Config

# --- Auth OTP delivery config (ALL envs) ----------------------------------------------------------
# MUST be here (not config.exs): config.exs is compile-time for a release, so it would bake the
# BUILD-time env (mode "none", api_key nil, enabled false) and ignore the running container's env.
# runtime.exs is evaluated at BOOT, so the release (and dev/test) read the actual env. Tests still
# override via Application.put_env after boot. DEFAULT "none" keeps prod safe (no plaintext OTP).
config :auth_service, otp_delivery_mode: System.get_env("OTP_DELIVERY_MODE") || "none"

# TOKEN LIFETIMES — read HERE, not in config.exs.
#
# These lived in config.exs, which Mix evaluates at BUILD time. The System.get_env calls therefore
# resolved against the build machine and were frozen into the release: setting
# AUTH_REFRESH_TOKEN_TTL_SECONDS on the running container did nothing, and no error said so. During a
# forced-logout investigation the deployed refresh lifetime could not be established from the compose
# file at all — the only reliable read was an rpc into the running node.
#
# Values and variable names are UNCHANGED; only the moment of evaluation moves. With no AUTH_* vars
# set (the current deployment) the defaults below resolve exactly as before: 900 / 2592000 /
# chat-platform / chat-platform-clients.
#
# All four are consumed at runtime through Tokens.token_config/2, so none of them is needed at
# compile time and the whole block moves together.
config :auth_service, :tokens,
  access_token_ttl_seconds:
    String.to_integer(System.get_env("AUTH_ACCESS_TOKEN_TTL_SECONDS") || "900"),
  refresh_token_ttl_seconds:
    String.to_integer(System.get_env("AUTH_REFRESH_TOKEN_TTL_SECONDS") || "2592000"),
  issuer: System.get_env("AUTH_TOKEN_ISSUER") || "chat-platform",
  audience: System.get_env("AUTH_TOKEN_AUDIENCE") || "chat-platform-clients"

# --- Shared Redis (ALL envs) ----------------------------------------------------------------------
# Backs the /v1 runtime (rate-limit counter + idempotency KV) and the OTP rate limiter. MUST be here,
# NOT config.exs: config.exs is compile-time for a release, so it would bake the BUILD-time value
# (localhost, no REDIS_URL) and ignore the running container's REDIS_URL — every Redis call would then
# silently fail-open and never touch Redis. runtime.exs is evaluated at BOOT. Tests pin the InMemory
# adapter (test.exs), so this URL is unused there.
config :shared_infra, :redis,
  url:
    System.get_env("RATE_LIMITER_REDIS_URL") ||
      System.get_env("REDIS_URL") ||
      "redis://localhost:6379/0",
  timeout: String.to_integer(System.get_env("RATE_LIMITER_REDIS_TIMEOUT_MS") || "1000")

config :shared_infra,
  rate_limiter_fail_open: System.get_env("RATE_LIMITER_FAIL_OPEN", "true") in ["true", "1", "yes"]

# LiveKit (Phase-1 calling). Read at BOOT — never baked (same lesson as the Kafka/media adapters). The
# API key/secret sign LiveKit access-token JWTs (SharedInfra.LiveKitToken); they are SEPARATE from the app
# TOKEN_SECRET. Unset key/secret → the token endpoint returns 503 calls.unavailable (no crash). URL is
# returned to the client to reach the SFU.
config :shared_infra, :livekit,
  api_key: System.get_env("LIVEKIT_API_KEY"),
  api_secret: System.get_env("LIVEKIT_API_SECRET"),
  url: System.get_env("LIVEKIT_URL") || "wss://livekit.growblic.com"

# OTP SMS delivery via SMSGatewayHub (DLT). Provider-selected by SMS_PROVIDER: "console" (default →
# no real SMS, no credits/DLT needed) or "smsgatewayhub" (real send). SMS_PROVIDER supersedes the legacy
# OTP_SMS_DELIVERY_ENABLED flag (kept for back-compat: true → smsgatewayhub when SMS_PROVIDER is unset).
# api_key/entity_id/template_login_id/route are secrets: env only, never committed. Keys match
# AuthService.SmsClient / AuthService.SMS exactly.
config :auth_service, :sms,
  provider: System.get_env("SMS_PROVIDER"),
  enabled: System.get_env("OTP_SMS_DELIVERY_ENABLED") in ["true", "1", "yes"],
  base_url: System.get_env("SMS_GATEWAY_HUB_BASE_URL") || "https://www.smsgatewayhub.com",
  send_path: System.get_env("SMS_GATEWAY_HUB_SEND_PATH") || "/api/mt/SendSMS",
  # HTTP method for the send. GET (default) — SendSMS is a query-param API; a bodyless POST → IIS 411.
  http_method: System.get_env("SMS_HTTP_METHOD"),
  api_key: System.get_env("SMS_GATEWAY_HUB_API_KEY"),
  senderid: System.get_env("SMS_GATEWAY_HUB_SENDER_ID") || "ISOOBC",
  channel: System.get_env("SMS_GATEWAY_HUB_CHANNEL") || "2",
  dcs: System.get_env("SMS_GATEWAY_HUB_DCS") || "0",
  flashsms: System.get_env("SMS_GATEWAY_HUB_FLASHSMS") || "0",
  route: System.get_env("SMS_GATEWAY_HUB_ROUTE"),
  entity_id: System.get_env("SMS_ENTITY_ID"),
  template_login_id: System.get_env("SMS_TEMPLATE_LOGIN_ID"),
  # Send the bare 10-digit national number (drop the country code) when true — some DLT/provider setups
  # require it. Default false (keeps the 91-prefixed number).
  strip_country_code: System.get_env("SMS_STRIP_COUNTRY_CODE") in ["true", "1", "yes"],
  # Message body template; `{code}` is replaced with the OTP. Must match the DLT-approved wording.
  otp_template: System.get_env("SMS_OTP_TEMPLATE"),
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
  config :media_service, MediaService.Repo, repo_opts

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
           # C7 dual-write: Postgres authoritative + detached Scylla shadow. OFF unless explicitly
           # selected — production stays "postgres" and deploying the code changes nothing.
           "dual_write" -> MessageService.MessageStore.DualWriteAdapter
           # C8 cutover ladder: shadow_read compares reads silently; scylla_read is THE FLIP with
           # writes still dual (rollback = select postgres/dual_write again, lossless).
           "shadow_read" -> MessageService.MessageStore.ShadowReadAdapter
           "scylla_read" -> MessageService.MessageStore.ScyllaReadAdapter
           "postgres" -> MessageService.MessageStore.PostgresAdapter
           "in_memory" -> MessageService.MessageStore.InMemoryAdapter
           _ -> MessageService.MessageStore.QueryPlanAdapter
         end)

    # THE SAME FACT, WHERE OTHER SERVICES CAN SEE IT. `:message_service` config is meaningless
    # outside the message container: the conversation release is [shared_infra, conversation_service],
    # so `Application.get_env(:message_service, :message_store_adapter)` there returns whatever
    # config.exs baked at BUILD time, not what this deployment is running. Reading it to decide
    # anything would be a check that can never fire — protection that looks real and is not.
    #
    # `:shared_infra` IS in every release, so this key travels. It is consumed by
    # `ConversationService.InboxCounters`, whose recount/reconcile SQL reads the Postgres `messages`
    # table directly and is therefore only correct while Postgres is the authoritative store.
    #
    # NOTE: it is only set for containers that actually receive MESSAGE_STORE_ADAPTER. A container
    # without it gets NO value, and the consumer treats "unknown" as "not Postgres" and stays inert.
    config :shared_infra, message_store_backend: adapter
  end

  if System.get_env("MEDIA_CLIENT_ADAPTER") == "http" do
    config :shared_infra, media_client_adapter: SharedInfra.MediaClientHttp
  end

  if url = System.get_env("MEDIA_SERVICE_URL") do
    config :shared_infra, media_service_url: url
  end

  # Media storage backend — selected at RUNTIME (same config.exs-baked trap as message_store_adapter
  # above: a release would bake QueryPlanAdapter despite MEDIA_STORAGE_ADAPTER=minio). minio →
  # MinioAdapter. Only overrides when set, so dev/test keep their compile-time default.
  if adapter = System.get_env("MEDIA_STORAGE_ADAPTER") do
    config :media_service,
      media_storage_adapter:
        (case adapter do
           "minio" -> MediaService.Storage.MinioAdapter
           "in_memory" -> MediaService.Storage.InMemoryAdapter
           _ -> MediaService.Storage.QueryPlanAdapter
         end)
  end

  # MinIO connection + signing config — runtime so the release respects the container env (config.exs
  # bakes build-time defaults). Presigned PUT/GET URLs are signed against MINIO_PUBLIC_ENDPOINT (a
  # browser-reachable host, e.g. http://localhost:9000) so the SigV4 host matches what the browser
  # actually hits; server-internal ops use MINIO_ENDPOINT (falls back to it when no public endpoint).
  if System.get_env("MINIO_ENDPOINT") || System.get_env("MINIO_PUBLIC_ENDPOINT") do
    config :media_service, :minio,
      endpoint: System.get_env("MINIO_ENDPOINT") || "http://localhost:9000",
      public_endpoint: System.get_env("MINIO_PUBLIC_ENDPOINT"),
      bucket: System.get_env("MINIO_BUCKET") || "chat-media",
      access_key_id:
        System.get_env("MINIO_ACCESS_KEY") || System.get_env("MINIO_ACCESS_KEY_ID") ||
          "minioadmin",
      secret_access_key:
        System.get_env("MINIO_SECRET_KEY") || System.get_env("MINIO_SECRET_ACCESS_KEY") ||
          "minioadmin",
      region: System.get_env("MINIO_REGION") || "us-east-1",
      url_expires_seconds:
        String.to_integer(System.get_env("MINIO_URL_EXPIRES_SECONDS") || "900"),
      path_style: System.get_env("MINIO_PATH_STYLE", "true") in ["true", "1", "yes"]
  end

  # Web-push VAPID keys (notification service's sender leg). Absent keys = push disabled cleanly
  # (subscriptions still register; nothing sends). NEVER ship the private key to any client build.
  if System.get_env("VAPID_PUBLIC_KEY") && System.get_env("VAPID_PRIVATE_KEY") do
    config :web_push_encryption, :vapid_details,
      subject: System.get_env("VAPID_SUBJECT") || "mailto:admin@growblic.com",
      public_key: System.get_env("VAPID_PUBLIC_KEY"),
      private_key: System.get_env("VAPID_PRIVATE_KEY")
  end

  # FCM push (notification service's ANDROID sender leg, Phase 2). Same shape as VAPID above:
  # absent credential = the leg is disabled cleanly (tokens still register; nothing sends).
  #
  #   FCM_PROJECT_ID              the Firebase project id (the <project_id> in the v1 send URL)
  #   FCM_SERVICE_ACCOUNT_JSON    the service-account JSON *contents* — for a container secret, or
  #   FCM_SERVICE_ACCOUNT_PATH    a path to the mounted JSON file
  #
  # The JSON contains a PRIVATE KEY. It is NEVER committed, never baked into an image and never
  # exposed to any client build — Android needs only the public google-services.json, which is a
  # different file. JSON wins over PATH when both are set.
  fcm_credentials =
    case {System.get_env("FCM_SERVICE_ACCOUNT_JSON"), System.get_env("FCM_SERVICE_ACCOUNT_PATH")} do
      {json, _path} when is_binary(json) and json != "" ->
        case Jason.decode(json) do
          {:ok, decoded} -> decoded
          _ -> nil
        end

      {_json, path} when is_binary(path) and path != "" ->
        with {:ok, contents} <- File.read(path),
             {:ok, decoded} <- Jason.decode(contents) do
          decoded
        else
          _ -> nil
        end

      _ ->
        nil
    end

  if System.get_env("FCM_PROJECT_ID") && fcm_credentials do
    config :notification_service, :fcm,
      project_id: System.get_env("FCM_PROJECT_ID"),
      credentials: fcm_credentials
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

  # --- ScyllaDB nodes (Phase A: container + schema only) -------------------------------------------
  # Env-gated exactly like KAFKA_BROKERS below: with SCYLLA_NODES ABSENT this writes NO config at all,
  # so dev, test, and every current deploy are byte-identical. It teaches the message service only
  # WHERE Scylla lives — it does NOT select the store: MESSAGE_STORE_ADAPTER (above) still decides and
  # remains "postgres". Nothing reads this yet; SharedInfra.Scylla.Client has no real driver until
  # Phase B, so a set value is inert rather than dangerous.
  #
  # SharedInfra.Config.Scylla expects nodes as {host, port} TUPLES, so parse rather than pass the raw
  # string: "scylla:9042" or "a:9042,b:9042"; a bare host defaults to 9042.
  if nodes = System.get_env("SCYLLA_NODES") do
    parsed =
      nodes
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn node ->
        case String.split(node, ":", parts: 2) do
          [host, port] -> {host, String.to_integer(port)}
          [host] -> {host, 9042}
        end
      end)

    config :message_service, :scylla,
      nodes: parsed,
      keyspace: System.get_env("SCYLLA_KEYSPACE") || "chat_messages"

    # Phase B: with nodes configured, point the client boundary at the REAL driver. Still DRIVER ONLY
    # — MESSAGE_STORE_ADAPTER (above) decides the store and remains "postgres". Without SCYLLA_NODES
    # this never runs, so the boundary keeps returning SharedInfra.Scylla.UnavailableClient exactly as
    # before, and tests keep pinning SharedInfra.TestAdapters.Scylla themselves.
    config :shared_infra, scylla_client_adapter: SharedInfra.Scylla.XandraAdapter
  end

  # --- Kafka brokers (only if provided; Kafka stays OFF on the first deploy via its flags) ---
  if brokers = System.get_env("KAFKA_BROKERS") do
    config :message_service, :kafka, brokers: brokers, client_id: "message-service"
    config :conversation_service, :kafka, brokers: brokers, client_id: "conversation-service"
    config :notification_service, :kafka, brokers: brokers, client_id: "notification-service"
    config :realtime_gateway, :kafka, brokers: brokers, client_id: "realtime-gateway"
  end

  # Kafka producer adapter — selected at RUNTIME (config.exs bakes NoopProducer at build time, so a
  # release ignores KAFKA_PRODUCER_ADAPTER=brod and never starts the brod client / never publishes).
  # Same baked-at-build trap as message_store_adapter / media_storage_adapter above. Fixes BOTH the
  # supervision-tree gate (brod client starts) AND the Producer.produce dispatch, for the message and
  # conversation services. Only overrides when set → dev/test keep the compile-time NoopProducer.
  if System.get_env("KAFKA_PRODUCER_ADAPTER") == "brod" do
    config :shared_infra, kafka_producer_adapter: SharedInfra.Kafka.BrodProducer
  end
end
