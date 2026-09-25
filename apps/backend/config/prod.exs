import Config

# Production COMPILE-TIME config. Real values (DATABASE_URL, secrets, host, origins) are read
# at BOOT in config/runtime.exs so a release reads the actual environment — keep this minimal.
# Its existence is also required: config.exs ends with `import_config "#{config_env()}.exs"`,
# which would fail under MIX_ENV=prod without this file.
config :logger, level: :info

# ECTO QUERY LOGGING IS OFF IN PROD, for every repo. Ecto's query log line prints the bound
# parameters verbatim — `SELECT ... WHERE phone_number IN $1 [["+1555..."]]` — and unlike Phoenix's
# request log it has NO parameter filter: the only knob is the level, or off. At :info it is never
# emitted anyway, so this costs nothing today; what it buys is that raising the logger level to
# :debug to chase a production bug cannot write address books, OTP destinations or match rows to the
# container log. runtime.exs merges its url/pool/ssl options INTO these entries (Config.Provider deep-
# merges keyword lists), so `log: false` survives boot — pinned by SharedInfra.ProdLogHygieneTest.
for {app, repo} <- [
      auth_service: AuthService.Repo,
      user_service: UserService.Repo,
      conversation_service: ConversationService.Repo,
      message_service: MessageService.Repo,
      notification_service: NotificationService.Repo,
      media_service: MediaService.Repo
    ] do
  config app, repo, log: false
end

# Prod-only: structured JSON logs so request_id / correlation_id are queryable fields in a log
# aggregator. Dev/test keep the plain console format (config.exs). Hand-rolled formatter, no dep.
config :logger, :console,
  format: {SharedInfra.Logging.JsonFormatter, :format},
  metadata: :all
