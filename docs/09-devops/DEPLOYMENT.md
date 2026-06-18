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

## Container image (sub-slice 2, done 2026-06-18)

[apps/backend/Dockerfile](../../apps/backend/Dockerfile) — multi-stage; **build context is `apps/backend`**
(so `apps/web` is naturally outside it). [apps/backend/.dockerignore](../../apps/backend/.dockerignore) keeps
the context lean (excludes `_build`, `deps`, per-app `test/`, `.git` — host-built macOS artifacts must not
leak into the linux build).

- **Build stage** — `elixir:1.18.4-otp-27` (matches CI's toolchain); installs `build-essential` + **`cmake`**
  (brod's `crc32cer` NIF — same reason CI needs it); `MIX_ENV=prod`; `mix deps.get --only prod`,
  `deps.compile`, `compile`, `mix release chat_platform`.
- **Runtime stage** — `debian:bookworm-slim` with ONLY runtime libs (`libstdc++6`, `openssl`, `libncurses6`,
  `ca-certificates`); NO mix/Erlang/build tools (ERTS is bundled by `mix release`). Runs as non-root `app`,
  `EXPOSE 4000`, `CMD ["bin/chat_platform", "start"]`.

**Secrets are NEVER baked in** — only source + config are COPYed; real secrets arrive via `-e`/secret store at
runtime and `config/runtime.exs` enforces the fail-fast guard. Final image ≈ **262 MB**.

Build & run:
```sh
cd apps/backend
docker build -t chat-platform-backend .
# Fails fast without secrets (guard fires):
docker run --rm chat-platform-backend bin/chat_platform eval "IO.puts(:ok)"   # → FATAL: DATABASE_URL is not set
# Boots with real secrets + env (DB connect still needs a reachable DATABASE_URL):
docker run --rm -p 4000:4000 \
  -e DATABASE_URL=... -e SECRET_KEY_BASE=... -e TOKEN_SECRET=... -e OTP_SECRET=... -e PHX_HOST=... \
  chat-platform-backend
```

**Verified locally (2026-06-18):** image builds (262 MB); container with no secrets fails fast
(`FATAL: DATABASE_URL is not set`); with valid dummy secrets `runtime.exs` evaluates cleanly
(`guard_passed_runtime_ok`); with a placeholder `SECRET_KEY_BASE` the guard rejects it
(`FATAL: ... known insecure placeholder`). A full serving boot against a real managed Postgres is
sub-slice 3.

## Hosting plan (recommended)

- **Backend:** Fly.io running the umbrella release (`MIX_ENV=prod mix release chat_platform`), websockets supported.
- **Postgres:** managed (Fly Postgres / Neon / Supabase). Apply schema from
  `infra/docker/postgres/init/*.sql` (the de-facto migrations — no Ecto migrations exist yet).
- **Web:** Vercel (Next.js), `NEXT_PUBLIC_API_BASE_URL` + `NEXT_PUBLIC_REALTIME_URL` → backend HTTPS/WSS.
- **Kafka:** deferred (flag-gated). Provision a managed broker (Upstash/Confluent/Redpanda) and flip the
  Kafka flags once core chat is proven live.

## Staged rollout

1. **(done) config + boot foundation** — guard, runtime/prod config, release, Repo supervision.
2. **(done) containerize** — multi-stage Dockerfile (cmake in build stage, slim runtime); image builds + guard fires in-container (verified above).
3. **(3a done) Fly config + runbook** — `fly.toml` + the ordered deploy runbook below; **(3b, user) actual `fly deploy`** to Fly + managed Postgres, core chat ON / Kafka OFF, schema applied, smoke-test `/health` + login + message round-trip.
4. Baseline observability (JSON logs, request/correlation-id threading, readiness `/health`).
5. Deploy web pointed at the backend.
6. Provision Kafka, flip the consumer/producer flags, verify produce/consume/fan-out live.

## Fly.io config (sub-slice 3a, done 2026-06-18)

[apps/backend/fly.toml](../../apps/backend/fly.toml) — deploy from `apps/backend` (build context +
Dockerfile live there). `[build] dockerfile = "Dockerfile"`; `[http_service] internal_port = 4000`,
`force_https`, `min_machines_running = 1` (keeps a machine up so websocket/channel sessions survive —
Fly proxies the HTTP→WS upgrade over the same port, clients use `wss://`, no extra config); `[[vm]]`
`shared-cpu-1x` / 512 MB. `[env]` carries the **core-chat-ON, Kafka-OFF** flag set and `PHX_HOST`
placeholder; **secrets are NOT in the file** (set via `fly secrets`/`fly postgres attach`). Validated by
inspection only — `flyctl` isn't installed here; `fly launch`/`fly deploy` validate it on your machine.

### Schema apply (no Ecto migrations)
The schema lives in `infra/docker/postgres/init/*.sql` (NOT Ecto migrations), and those files are **not**
in the release image (build context is `apps/backend`; `infra/` is outside it). So the first deploy
applies the schema **manually, once**, in order `001 → 042`, against the managed Postgres (step 4 below).
A bundled-migration story is future work.

## First-deploy runbook (Fly.io) — run on YOUR machine

> Staged rollout: **core chat ON, Kafka OFF.** Replace `chat-platform` / region as you like.

1. **Install + auth flyctl**
   ```sh
   curl -L https://fly.io/install.sh | sh        # or: brew install flyctl
   fly auth login
   ```
2. **Create the app (no deploy yet)** — from `apps/backend`, edit `fly.toml` `app` + `PHX_HOST` first:
   ```sh
   cd apps/backend
   fly apps create chat-platform            # or `fly launch --no-deploy --copy-config --name chat-platform`
   ```
3. **Provision + attach managed Postgres** (sets `DATABASE_URL` as a secret automatically):
   ```sh
   fly postgres create --name chat-platform-db --region iad
   fly postgres attach chat-platform-db --app chat-platform
   ```
4. **Apply the schema (once, ordered)** — open a proxy to the managed PG, then run the init SQL in order:
   ```sh
   fly proxy 15432:5432 -a chat-platform-db &           # tunnel localhost:15432 → managed PG
   # DATABASE_URL was printed by `attach`; use that user/password/db here:
   for f in ../../infra/docker/postgres/init/0*.sql; do
     echo "applying $f"; psql "postgresql://USER:PASS@localhost:15432/DBNAME?sslmode=disable" -f "$f" || break
   done
   ```
   Order matters (`001_extensions` → … → `042_notifications_fanout`); stop on first error.
5. **Set secrets** (never commit these):
   ```sh
   fly secrets set \
     SECRET_KEY_BASE="$(openssl rand -base64 48)" \
     TOKEN_SECRET="$(openssl rand -base64 32)" \
     OTP_SECRET="$(openssl rand -base64 32)" \
     -a chat-platform
   # DATABASE_URL is already set by `attach`. Core-chat flags live in fly.toml [env].
   ```
   (`SECRET_KEY_BASE` can also be `mix phx.gen.secret`.) Confirm none equal a `*-change-before-production`
   placeholder — the boot guard rejects those.
6. **Deploy**
   ```sh
   fly deploy
   ```
7. **Smoke test** (against `https://chat-platform.fly.dev`):
   ```sh
   curl -sf https://chat-platform.fly.dev/health        # → {"status":"ok","service":"api_gateway"}
   # OTP login: POST /auth/otp/request then /auth/otp/verify, then create + list a message in a
   # conversation (see docs/05-api-contracts). A WS round-trip needs the web client (sub-slice 5).
   ```
8. **Logs / rollback**
   ```sh
   fly logs -a chat-platform            # tail boot + request logs
   fly releases -a chat-platform        # list releases
   fly deploy --image <previous>        # or `fly releases rollback` to revert
   ```

## EXPECT a debug loop — likely first failures

| Symptom | Cause | Fix |
|---|---|---|
| Boot crash `FATAL: <VAR> is not set` / `insecure placeholder` | The prod guard fired — a required secret is missing or a placeholder | `fly secrets set` a real `SECRET_KEY_BASE`/`TOKEN_SECRET`/`OTP_SECRET`; ensure `DATABASE_URL` is attached |
| Boot connects then `:econnrefused`/SSL errors to PG | TLS/sslmode mismatch with managed PG | runtime.exs defaults `DATABASE_SSL=true` + `verify_none`; if the provider needs no TLS set `DATABASE_SSL=false`, or supply CA certs to harden |
| App boots but every DB request 500s (`relation does not exist`) | Schema not applied | Run step 4 (the ordered init SQL) against the managed PG |
| Websocket fails to connect from the browser (`check_origin`) | Origin not allowed | Set `WEB_ORIGIN=https://your-web-url` (comma-sep list) via `fly secrets`; until set, `check_origin` is `false` (allow-all) so this only bites after you lock it down |
| Login "works" but tokens/OTP behave oddly across restarts | A DB-backed flag left OFF → placeholder path | Confirm all core-chat flags in `fly.toml [env]` are `true` (incl. `MESSAGE_STORE_ADAPTER=postgres`) |
| Health OK but realtime identity untrusted | `REALTIME_AUTH_DB_BACKED` without `AUTH_SESSION_DB_BACKED` | Both must be `true` together (fail-closed socket); both are set in `fly.toml [env]` |
| Machine stops, WS drops | `auto_stop_machines` idled the only machine | `min_machines_running = 1` is set; raise it / disable auto-stop if needed |

## Verified here vs deploy-only

- **Code/config-verified:** guard raises on missing/placeholder & passes on a real secret (unit tests +
  in-container); Repo gate off in `:test` / on in dev; plain `mix test` intact (200/73; 268 pg); release
  builds; Docker image builds (≈262 MB) and the guard fires in-container; `fly.toml` is well-formed by
  inspection; `runtime.exs` reads every value the Fly boot needs.
- **Deploy-only (NOT verifiable here — the USER's next step is the real proof):** actual `fly deploy`,
  managed-PG TLS/sslmode, schema applied to managed PG, public WSS handshake / `check_origin`, the
  end-to-end smoke test. `flyctl` is not installed in this environment, so the deploy itself is run by
  the user.
