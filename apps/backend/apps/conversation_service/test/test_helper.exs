ExUnit.start()

ExUnit.configure(
  exclude: [postgres_integration: true, kafka_integration: true, http_integration: true]
)
