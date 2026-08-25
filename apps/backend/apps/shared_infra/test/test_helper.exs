ExUnit.start()

ExUnit.configure(
  exclude: [
    redis_integration: true,
    kafka_integration: true,
    http_integration: true,
    # Real-postgres suites (scripts/test-postgres.sh) — the default path stays Docker-free.
    postgres_integration: true,
    # Live ScyllaDB round-trip (Phase B). Needs `--profile scylla up -d scylla`; run with
    # `SCYLLA_TEST_NODES=localhost:9042 mix test --include scylla_integration`.
    scylla_integration: true
  ]
)
