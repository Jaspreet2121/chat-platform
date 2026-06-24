import Config

# Production COMPILE-TIME config. Real values (DATABASE_URL, secrets, host, origins) are read
# at BOOT in config/runtime.exs so a release reads the actual environment — keep this minimal.
# Its existence is also required: config.exs ends with `import_config "#{config_env()}.exs"`,
# which would fail under MIX_ENV=prod without this file.
config :logger, level: :info

# Prod-only: structured JSON logs so request_id / correlation_id are queryable fields in a log
# aggregator. Dev/test keep the plain console format (config.exs). Hand-rolled formatter, no dep.
config :logger, :console,
  format: {SharedInfra.Logging.JsonFormatter, :format},
  metadata: :all
