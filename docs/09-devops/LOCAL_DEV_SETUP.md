# Local Development Setup

## Purpose

This document explains how to run local infrastructure for chat-platform.

Local development uses Docker Compose.

## Required Tools

- Git
- Docker
- Docker Compose
- VS Code
- Node.js later for frontend
- Elixir/Erlang later for backend

## Local Services

| Service | Purpose | Port |
|---|---|---|
| PostgreSQL | Transactional database | 5432 |
| Redis | Cache, presence, typing, rate limits | 6379 |
| ScyllaDB | Chat message timeline | 9042 |
| Kafka | Event streaming | 9094 |
| Kafka UI | Kafka management UI | 8080 |
| MinIO | S3-compatible object storage | 9000, 9001 |
| Mailpit | Local email testing | 1025, 8025 |

## Start Local Infra

From project root:

```bash
make infra-up
```

Equivalent Docker Compose command:

```bash
docker compose -f infra/docker/docker-compose.yml up -d
```

Stop local infra:

```bash
make infra-down
```

## Backend Checks

Run the normal Docker-free backend suite:

```bash
make backend-test
```

Run formatting and compile checks:

```bash
make backend-format
make backend-compile
```

## Web Frontend

The web MVP is in `apps/web`.

Initial setup:

```bash
cd apps/web
cp .env.example .env.local
npm install
```

Default local env:

```env
NEXT_PUBLIC_API_BASE_URL=http://localhost:4000
NEXT_PUBLIC_REALTIME_URL=ws://localhost:4000/socket
```

Run the app:

```bash
make web-dev
```

Run frontend checks:

```bash
make web-lint
make web-build
```

The current web MVP uses browser `localStorage` for access and refresh tokens.
That is intentionally simple for the first frontend slice and should be
hardened before production.

## Redis-backed Rate Limiting

The API Gateway can protect `POST /api/v1/auth/otp/request` with the shared
rate limiter. Normal tests use an in-memory adapter and do not require Redis.

For local Redis-backed rate limiting, start Redis and enable the route-level
flag:

```bash
make infra-up
cd apps/backend
API_RATE_LIMITING_ENABLED=true \
RATE_LIMITER_REDIS_URL=redis://localhost:6379/0 \
RATE_LIMITER_FAIL_OPEN=true \
RATE_LIMITER_REDIS_TIMEOUT_MS=1000 \
mix phx.server
```

`RATE_LIMITER_FAIL_OPEN=true` preserves availability if Redis is temporarily
unreachable. Set it to `false` when you want Redis errors to surface as
`rate_limiter_unavailable` from the shared boundary.

Run the optional live Redis adapter test with:

```bash
cd apps/backend
RATE_LIMITER_REDIS_URL=redis://localhost:6379/0 mix test --include redis_integration apps/shared_infra/test
```

## MinIO Presigned Media URLs

The media service can generate MinIO/S3 presigned upload and download URLs
without uploading file bytes from the backend. Normal tests use safe
non-networked adapters and do not require MinIO.

For local presigned URLs, start MinIO and enable media persistence plus the
MinIO adapter:

```bash
make infra-up
cd apps/backend
MEDIA_DB_BACKED=true \
MEDIA_STORAGE_ADAPTER=minio \
MINIO_ENDPOINT=http://localhost:9000 \
MINIO_BUCKET=chat-media \
MINIO_ACCESS_KEY=minioadmin \
MINIO_SECRET_KEY=minioadmin \
MINIO_REGION=us-east-1 \
MINIO_URL_EXPIRES_SECONDS=900 \
MINIO_PATH_STYLE=true \
mix phx.server
```

This slice only signs URLs. Bucket creation, live upload verification, object
metadata persistence, and media access checks are still separate follow-up
work.

## Scylla-backed Message Storage

Message Service can route message create/list/edit/delete and delivered/read
receipt operations through the Scylla adapter boundary. Normal tests use
in-memory or query-plan adapters and do not require ScyllaDB.

Local Scylla config placeholders:

```bash
MESSAGE_DB_BACKED=true
MESSAGE_STORE_ADAPTER=scylla
SCYLLA_CONTACT_POINTS=localhost:9042
SCYLLA_KEYSPACE=chat_messages
SCYLLA_TIMEOUT_MS=5000
```

The current backend does not include a live Cassandra/Scylla driver dependency.
`SharedInfra.Scylla.Client` is the configured client boundary, and its default
adapter returns unavailable until a driver adapter is explicitly provided.

## PostgreSQL Test Database

Backend PostgreSQL integration tests use a separate local database named
`chat_platform_test` by default. These tests are opt-in and are excluded from
plain `mix test` so the normal suite does not require a live database.

From the project root, start PostgreSQL and prepare the test database:

```bash
cd infra/docker
docker compose up -d postgres
docker exec chat-platform-postgres createdb -U chat_user chat_platform_test
cd ../..
docker exec -i chat-platform-postgres psql -U chat_user -d chat_platform_test < infra/docker/postgres/init/010_initial_schema.sql
```

If the database already exists, drop and recreate it before loading the schema:

```bash
docker exec chat-platform-postgres dropdb -U chat_user --if-exists chat_platform_test
docker exec chat-platform-postgres createdb -U chat_user chat_platform_test
docker exec -i chat-platform-postgres psql -U chat_user -d chat_platform_test < infra/docker/postgres/init/010_initial_schema.sql
```

### Docker PostgreSQL on Port 5432

Use this path when no other local PostgreSQL process is listening on port 5432.

```bash
cd apps/backend
POSTGRES_TEST_HOST=localhost POSTGRES_TEST_PORT=5432 mix test --include postgres_integration
```

### Docker PostgreSQL on an Alternate Port

Use this path if you keep another local PostgreSQL process running on port 5432
and choose to map Docker PostgreSQL to a different host port later, for example
`55432:5432`.

Prepare the test database inside the container the same way, then point the
backend tests at the alternate host port:

```bash
cd apps/backend
POSTGRES_TEST_HOST=localhost POSTGRES_TEST_PORT=55432 mix test --include postgres_integration
```

Run the normal backend suite without database integration tests:

```bash
make backend-test
```

Run the opt-in PostgreSQL integration tests:

```bash
make backend-test-integration
```

Override connection settings with `TEST_DATABASE_URL` or the local placeholders
`POSTGRES_TEST_HOST`, `POSTGRES_TEST_PORT`, `POSTGRES_TEST_USER`,
`POSTGRES_TEST_PASSWORD`, and `POSTGRES_TEST_DATABASE`.

For backward compatibility, test config falls back to `POSTGRES_HOST`,
`POSTGRES_PORT`, `POSTGRES_USER`, and `POSTGRES_PASSWORD` when the dedicated
test variables are not set.

If integration tests fail with `role "chat_user" does not exist`, another local
PostgreSQL process may be bound to `127.0.0.1:5432` ahead of the Docker
published port. Check the listener with:

```bash
lsof -nP -iTCP:5432 -sTCP:LISTEN
```

Stop the local PostgreSQL process, or point `POSTGRES_TEST_HOST` and
`POSTGRES_TEST_PORT` at a prepared PostgreSQL test database that contains the
schema above. Keep plain `mix test` as the default local check when the test
database is not available.

## CI Notes

The default backend GitHub Actions workflow does not start Docker services. It
runs `mix deps.get`, `mix format --check-formatted`,
`mix compile --warnings-as-errors`, and `mix test` from `apps/backend`.

PostgreSQL integration tests remain opt-in locally for now. A CI integration
job should create a PostgreSQL service database, load
`infra/docker/postgres/init/010_initial_schema.sql`, set `POSTGRES_TEST_*`
variables, and then run `mix test --include postgres_integration`.

The Redis-backed rate limiter and MinIO/S3 presigned URL adapters are available
behind config. ScyllaDB message storage has a shared client boundary, with live
driver execution still deferred. The normal test suite stays Docker-free.
