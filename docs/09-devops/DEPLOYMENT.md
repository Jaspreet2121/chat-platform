# Deployment

Status (2026-06-18): **sub-slice 1 done — config + boot foundation is code-verified; no actual
deploy yet.** What exists now: production fail-fast secret guard, `config/runtime.exs` +
`config/prod.exs`, a `mix release` config, and Repos supervised at boot (gated off in `:test`).
A real deploy (containerize → host → managed Postgres) is sub-slices 2–3.

## Boot model (what changed)

Each service that owns a Repo (`auth`, `user`, `conversation`, `message`, `notification`) now
supervises its Repo at boot **in dev/prod**, so a booted server can serve DB-backed requests. In
`:test` the Repo is NOT started at boot (`config :<app>, start_repo: false` in `config/test.exs`);
`DataCase` starts it per-test, so plain `mix test` stays Docker-free. Verified: gate is `false` in
`:test`, `true` in `:dev`/`:prod`. `api_gateway` supervises the Endpoint (serves at runtime via
`server: true` set in `runtime.exs`).

## Production fail-fast secret guard

`config/runtime.exs` runs the `:prod` branch only (`config_env() == :prod`); dev/test are untouched.
It calls `SharedInfra.ProdConfig` to **refuse to boot** if any required secret is missing or equals a
known insecure placeholder (`*-change-before-production`, `*-placeholder-*`):

- `SECRET_KEY_BASE` — Phoenix endpoint signing.
- `TOKEN_SECRET` — refresh-token HMAC (`AuthService.Tokens`); wired as `:auth_service, :token_secret`.
- `OTP_SECRET` — OTP code HMAC (`AuthService.Otp`); wired as `:auth_service, :otp_secret`.
- `DATABASE_URL` — required (present-check).

The guard logic is unit-tested (`SharedInfra.ProdConfigTest`) without booting prod.

## Required production env

| Var | Purpose |
|---|---|
| `DATABASE_URL` | Managed Postgres connection (all 5 service Repos share it for the first deploy) |
| `SECRET_KEY_BASE` | Endpoint signing (generate with `mix phx.gen.secret`) |
| `TOKEN_SECRET` | Refresh-token HMAC |
| `OTP_SECRET` | OTP code HMAC |
| `PHX_HOST` | Public host for URL generation (e.g. `api.example.com`) |
| `PORT` | HTTP listen port (default 4000) |
| `WEB_ORIGIN` | Comma-separated allowed origins for the websocket `check_origin` (unset ⇒ check disabled — set it to lock down WSS) |
| `POOL_SIZE` | DB pool size (default 10) |
| `DATABASE_SSL` | `true` (default) ⇒ TLS to managed PG (`verify_none` first-deploy default; harden with CA certs later) |

### Feature flags for a "core chat ON, Kafka OFF" first deploy

Turn ON (DB-backed core chat): `AUTH_SESSION_DB_BACKED`, `AUTH_REFRESH_TOKEN_DB_BACKED`,
`AUTH_LOGOUT_DB_BACKED`, `AUTH_OTP_REQUEST_DB_BACKED`, `AUTH_OTP_VERIFY_DB_BACKED`,
`USER_PROFILE_DB_BACKED`, `CONVERSATION_DB_BACKED`, `MESSAGE_DB_BACKED` + `MESSAGE_STORE_ADAPTER=postgres`,
and (for trustworthy realtime identity) `REALTIME_AUTH_DB_BACKED=true` **with** `AUTH_SESSION_DB_BACKED=true`.

Leave OFF initially (staged rollout): `KAFKA_PRODUCER_ADAPTER` (default NoopProducer), `KAFKA_PUBLISH_ENABLED`,
`KAFKA_CONSUMER_ENABLED`, `KAFKA_PROJECTION_CONSUMER_ENABLED`, `CONVERSATION_PUBLISH_ENABLED`,
`NOTIFICATION_CONSUMER_ENABLED`, `NOTIFICATION_PARTICIPANTS_CONSUMER_ENABLED`. Media (`MEDIA_DB_BACKED`,
MinIO) and Scylla also stay off.

## Hosting plan (recommended)

- **Backend:** Fly.io running the umbrella release (`MIX_ENV=prod mix release chat_platform`), websockets supported.
- **Postgres:** managed (Fly Postgres / Neon / Supabase). Apply schema from
  `infra/docker/postgres/init/*.sql` (the de-facto migrations — no Ecto migrations exist yet).
- **Web:** Vercel (Next.js), `NEXT_PUBLIC_API_BASE_URL` + `NEXT_PUBLIC_REALTIME_URL` → backend HTTPS/WSS.
- **Kafka:** deferred (flag-gated). Provision a managed broker (Upstash/Confluent/Redpanda) and flip the
  Kafka flags once core chat is proven live.

## Staged rollout

1. **(done) config + boot foundation** — guard, runtime/prod config, release, Repo supervision.
2. Containerize (Dockerfile for the release, including `cmake`/`build-essential` for brod's `crc32cer` NIF).
3. Deploy backend + managed Postgres, core chat flags ON, Kafka OFF; smoke-test `/health`, login, message round-trip.
4. Baseline observability (JSON logs, request/correlation-id threading, readiness `/health`).
5. Deploy web pointed at the backend.
6. Provision Kafka, flip the consumer/producer flags, verify produce/consume/fan-out live.

## Verified here vs deploy-only

- **Code-verified:** guard raises on missing/placeholder & passes on a real secret (unit tests); Repo
  gate is off in `:test` / on in dev; plain `mix test` unchanged-intact (192) + guard tests (→200);
  release/runtime config compiles.
- **Deploy-only (NOT verified here):** an actual release boot, real `DATABASE_URL` + managed-PG TLS,
  public WSS handshake / `check_origin`, secret-store wiring. These surface in sub-slice 3.
