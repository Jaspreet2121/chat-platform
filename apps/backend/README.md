# Backend Umbrella

Phoenix/Elixir backend foundation for `chat-platform`.

## Structure

```txt
apps/backend/
  config/
  apps/
    api_gateway/
    auth_service/
    user_service/
    conversation_service/
    message_service/
    realtime_gateway/
```

This is an umbrella-style backend. `api_gateway` is the public HTTP entry point. The service apps are intentionally thin placeholders for future microservice extraction.

## Local Prerequisites

- Elixir and Erlang/OTP
- Phoenix archive if using Phoenix generators later
- Docker and Docker Compose for local infrastructure

Start infrastructure from the repository root:

```bash
cd infra/docker
docker compose up -d
```

Then run the backend from this directory:

```bash
cd apps/backend
mix deps.get
mix compile
mix phx.server
```

The API Gateway health check is available after the server starts:

```bash
curl http://localhost:4000/health
```

Run the `curl` command from a second terminal while `mix phx.server` keeps running.
The service apps currently keep database repo modules as placeholders, but they do not start database connections during boot.

## Configuration

Development defaults point at local Docker services:

- PostgreSQL: `localhost:5432`
- Redis: `localhost:6379`
- ScyllaDB: `localhost:9042`
- Kafka: `localhost:9094`

Override with environment variables such as `DATABASE_URL`, `REDIS_URL`, `SCYLLA_HOST`, `SCYLLA_PORT`, `KAFKA_BROKERS`, and `SECRET_KEY_BASE`. Do not commit real secrets.

For the current Docker Compose development database, set `DATABASE_URL` to match your local `.env` or Compose credentials before starting the backend.
