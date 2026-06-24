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

## Per-service images (microservices split, done 2026-06-23)

The single [apps/backend/Dockerfile](../../apps/backend/Dockerfile) is now **parameterized** by a `RELEASE`
build-arg (one Dockerfile, not six — the release name is the only thing that varies; build context, build/runtime
stages, and the secret guard are identical). With no build-arg it defaults to `RELEASE=chat_platform` →
reproduces the original all-in-one image (the 3b baseline is unchanged). Each per-service image bundles ONLY that
app + `shared_infra` (+ hex deps + ERTS), NOT the other services — `mix release <name>` selects the subset (see
[apps/backend/mix.exs](../../apps/backend/mix.exs) `releases:`).

| RELEASE | apps bundled | port (build-arg `SERVICE_PORT`) | env to enable its listener |
|---|---|---|---|
| `auth_service` | auth_service + shared_infra | 4101 | `AUTH_HTTP_API_ENABLED=true` |
| `conversation_service` | conversation_service + shared_infra | 4102 | `CONVERSATION_HTTP_API_ENABLED=true` |
| `user_service` | user_service + shared_infra | 4103 | `USER_HTTP_API_ENABLED=true` |
| `message_service` | message_service + shared_infra | 4104 | `MESSAGE_HTTP_API_ENABLED=true` |
| `media_service` | media_service + shared_infra | 4105 | `MEDIA_HTTP_API_ENABLED=true` |
| `gateway` | api_gateway + realtime_gateway + shared_infra | 4000 | (serves by default) |
| `chat_platform` | all 9 apps (all-in-one) | 4000 | default build |

```sh
# from repo root (build context = apps/backend):
docker build --build-arg RELEASE=auth_service --build-arg SERVICE_PORT=4101 -t chat/auth_service apps/backend
docker build --build-arg RELEASE=gateway      --build-arg SERVICE_PORT=4000 -t chat/gateway      apps/backend
docker build                                                                -t chat/all          apps/backend  # chat_platform
```

The runtime `CMD` is `exec /app/bin/$RELEASE_BIN start` (release name carried via the `RELEASE_BIN` env so the
shell-form CMD can read it; `exec` makes the release PID 1 so `SIGTERM` reaches the VM).

**NOTE — shared `runtime.exs`:** every release evaluates the same `config/runtime.exs`, so in `:prod` ALL of
`DATABASE_URL`, `SECRET_KEY_BASE`, `TOKEN_SECRET`, `OTP_SECRET`, `PHX_HOST` must be present even for a non-gateway
service container (`PHX_HOST` is a gateway concern but is currently required for every release — set it to any
hostname for a pure service). Refining the guard to be per-release is a later option; not needed for the first
multi-container deploy.

**Verified locally (2026-06-23, Docker available):**
- Built `chat/auth_service` and `chat/gateway` for real — both succeed, **≈ 259 MB** each.
- `docker run chat/auth_service` with NO secrets → fails fast (`FATAL: DATABASE_URL is not set`, then `PHX_HOST`),
  proving no secrets baked + the per-service release boots far enough to enforce the guard.
- `docker run chat/auth_service` with dummy-valid secrets + `AUTH_HTTP_API_ENABLED=true -e AUTH_HTTP_PORT=4101 -p
  4101:4101` → **boots and listens**: host `curl -X POST :4101/internal/session/current` → **HTTP 401** (the
  `TokenPlug` rejecting unauthenticated calls, fail-closed). Postgres connection retries in the background against
  the absent DB without crashing boot (expected — nothing to talk to yet).

## Multi-container bring-up — docker-compose.prod.yml (done 2026-06-23)

[docker-compose.prod.yml](../../docker-compose.prod.yml) (repo root) runs each service as its OWN container on a
shared bridge network (`chatnet`), with the **gateway flipped to the HTTP client adapters** so it calls the
services over the network (`*_CLIENT_ADAPTER=http` + `*_SERVICE_URL=http://<svc>:<port>`). Core chat only —
Kafka/Redis/Scylla/MinIO are intentionally absent (staged rollout; their flags stay off). The dev infra compose
([infra/docker/docker-compose.yml](../../infra/docker/docker-compose.yml)) still has those for later.

**Containers + ports** (service ports are internal/`expose`d on `chatnet`; only the gateway publishes to the host):

| container | RELEASE | internal port | enable + DB flag |
|---|---|---|---|
| postgres | postgres:16-alpine | 5432 | `chat_user` / `chat_platform`, named volume `pgdata`, healthcheck |
| auth | auth_service | 4101 | `AUTH_HTTP_API_ENABLED=true`, `AUTH_SESSION_DB_BACKED=true` |
| conversation | conversation_service | 4102 | `CONVERSATION_HTTP_API_ENABLED=true`, `CONVERSATION_DB_BACKED=true` |
| user | user_service | 4103 | `USER_HTTP_API_ENABLED=true`, `USER_PROFILE_DB_BACKED=true` |
| message | message_service | 4104 | `MESSAGE_HTTP_API_ENABLED=true`, `MESSAGE_DB_BACKED=true`, `MESSAGE_STORE_ADAPTER=postgres` |
| media | media_service | 4105 | `MEDIA_HTTP_API_ENABLED=true`, `MEDIA_DB_BACKED=true` (full object storage needs MinIO — deferred) |
| **gateway** | gateway | **4000 → host 4000** | all 5 `*_CLIENT_ADAPTER=http` + `*_SERVICE_URL` |

**Schema** is applied automatically: `infra/docker/postgres/init` (001..042, ordered) is mounted into the
postgres container's `/docker-entrypoint-initdb.d`. Postgres auto-runs those `*.sql` IN FILENAME ORDER on the
FIRST init of an empty volume — so the full schema exists before any service connects. (Verified: 36 tables.)

**Shared `INTERNAL_API_TOKEN`** — one value across the gateway + every service (from `.env`); `TokenPlug` rejects
mismatches with 401.

### Runbook (run on YOUR machine)

```sh
# 1. Secrets → .env (compose auto-loads it from the repo root). Generate each with openssl:
cp .env.prod.example .env
# edit .env and set (each a long random value):
#   INTERNAL_API_TOKEN=$(openssl rand -hex 32)
#   SECRET_KEY_BASE=$(openssl rand -hex 64)      # or: (cd apps/backend && mix phx.gen.secret)
#   TOKEN_SECRET=$(openssl rand -hex 32)
#   OTP_SECRET=$(openssl rand -hex 32)

# 2. Build all images (one umbrella compile, shared across releases; then 6 release assemblies).
docker compose -f docker-compose.prod.yml build

# 3. Start. Postgres comes up + runs the init SQL on first boot; services wait for it (healthcheck).
docker compose -f docker-compose.prod.yml up -d

# 4. Wait for health + schema (first boot runs 001..042 — a few seconds).
curl -s localhost:4000/health           # → {"status":"ok","service":"api_gateway"}
docker compose -f docker-compose.prod.yml exec postgres \
  psql -U chat_user -d chat_platform -c "\dt" | tail -5   # tables present

# 5. Smoke test the cross-network path (these traverse gateway → service over HTTP):
curl -i localhost:4000/api/v1/auth/session -H 'authorization: Bearer bogus'   # → 401 auth.session_invalid (gateway reached auth)
curl -i -X POST localhost:4000/api/v1/auth/otp/request \
  -H 'content-type: application/json' -d '{"email":"you@example.com"}'        # → gateway → auth (OTP). A full
#   OTP login + message round-trip (gateway→auth, gateway→conversation membership, gateway→message) needs an
#   email channel to read the OTP (Mailpit is in the dev infra compose); add it to exercise the full login.

# Logs / restart one service:
docker compose -f docker-compose.prod.yml logs -f gateway      # or: auth | conversation | message | ...
docker compose -f docker-compose.prod.yml restart message

# Tear down (keep data):           docker compose -f docker-compose.prod.yml down
# Tear down + wipe DB volume:       docker compose -f docker-compose.prod.yml down -v
```

**Startup ordering:** services wait for postgres' healthcheck (`depends_on: condition: service_healthy`); the
gateway waits only for the services to START (not be ready — the slim release images have no `curl` for a readiness
probe). If the gateway calls a service before it's listening, the HTTP adapters return `{:error, :*_unavailable}`
→ **503** (not a crash), and it recovers automatically once the service is up. This is the failure semantics built
in the client-adapter slices paying off.

### Debug loop — likely first multi-container failures (symptom → cause → fix)

- **503 `*.unavailable` right after `up`** → gateway reached a service before it finished booting (or that service
  crashed). *Fix:* usually transient — retry after a few seconds; if persistent, `docker compose logs <svc>` to see
  why that container isn't listening.
- **401 from a service on every call (even valid)** → `INTERNAL_API_TOKEN` differs between the gateway and that
  service. *Fix:* it must be IDENTICAL everywhere; it comes from one `.env` value, so rebuild/recreate after editing
  `.env` (`up -d` re-reads env; a running container keeps its old env).
- **Service can't resolve `http://auth:4101`** → not on the same compose network, or a typo in `*_SERVICE_URL`.
  *Fix:* all services share `chatnet`; the host in `*_SERVICE_URL` must equal the compose SERVICE name.
- **Relation/table does not exist** → schema not applied. Postgres only runs `/docker-entrypoint-initdb.d` on a
  FRESH (empty) volume; if `pgdata` was already initialized (e.g. before the init mount was added), the SQL is
  skipped. *Fix:* `docker compose -f docker-compose.prod.yml down -v` to wipe the volume, then `up` again.
- **A service behaves as if persistence is off** (data not saved) → its `*_DB_BACKED` flag isn't set. *Fix:* set
  the right flag (table above); for message also `MESSAGE_STORE_ADAPTER=postgres`.
- **`FATAL: PHX_HOST is not set` / `DATABASE_URL is not set` on boot** → a required prod env var is missing. *Fix:*
  every release needs the full secret set + `PHX_HOST` (see the shared-`runtime.exs` note above); they come from
  `.env` via the compose `x-secrets` anchor.
- **Port 4000 already in use** → something else holds the host port. *Fix:* stop it, or change the gateway's
  published port mapping in the compose file.

## Self-hosted deploy runbook — your own Linux server (deploy 3b, 2026-06-24)

Run the full `docker-compose.prod.yml` stack on your own box. **No code blockers remain** — schema auto-loads
(the postgres `docker-entrypoint-initdb.d` mount → 36 tables on a fresh volume; `load_schema` is the Fly/managed-PG
path, moot here) and OTP SMS delivery is wired. All host config is `.env`; the compose file needs no edits.

**Server prereqs:** Linux, **≥ 4 GB RAM** (8 GB recommended — Kafka's JVM is the dominant cost ~1 GB), Docker +
Compose v2, port **4000** open (+ 80/443 if you front it with a TLS proxy).

**1. `.env`** (in the repo root, next to `docker-compose.prod.yml` — compose auto-loads it; gitignored):
```sh
SECRET_KEY_BASE=$(openssl rand -hex 64)
TOKEN_SECRET=$(openssl rand -hex 32)
OTP_SECRET=$(openssl rand -hex 32)
INTERNAL_API_TOKEN=$(openssl rand -hex 32)
PHX_HOST=<server-ip-or-domain>          # e.g. 203.0.113.10  (defaults to localhost if unset)
# OTP SMS (SMSGatewayHub/DLT) — enable + provide secrets to send real OTPs:
OTP_SMS_DELIVERY_ENABLED=true
SMS_GATEWAY_HUB_API_KEY=<your rotated API key>
SMS_GATEWAY_HUB_SENDER_ID=ISOOBC
SMS_GATEWAY_HUB_ROUTE=<route id>
SMS_ENTITY_ID=<DLT entity/PE id>
SMS_TEMPLATE_LOGIN_ID=<DLT LOGIN template id>
# WEB_ORIGIN=https://<web-host>          # optional — set once the web URL is known to lock the socket
```
Only `SECRET_KEY_BASE`/`TOKEN_SECRET`/`OTP_SECRET`/`INTERNAL_API_TOKEN` are *required* (compose errors if unset).
The SMS vars + `PHX_HOST`/`WEB_ORIGIN` are env-driven on the **auth** + shared containers — never hardcoded.

> ⚠️ **PRE-FLIGHT before enabling SMS:** the app generates **6-digit** OTPs — confirm your DLT LOGIN template's
> `{#var#}` accepts 6 digits (else SMSGatewayHub returns ErrorCode 024). And **rotate** the API key if it was ever
> shared in plaintext.

**2. Bring up:**
```sh
docker compose -f docker-compose.prod.yml up -d --build
```
**3. Verify:**
```sh
docker compose -f docker-compose.prod.yml ps        # 10 running + kafka-init/minio-init Exited(0)
curl -s http://<server>:4000/health                 # → {"status":"ok","service":"api_gateway"}
docker compose -f docker-compose.prod.yml exec postgres \
  psql -U chat_user -d chat_platform -c "\dt" | tail -3   # 36 tables (auto-loaded on first volume init)
```
**4. Frontend** (deploys separately — not in this compose):
```
NEXT_PUBLIC_API_BASE_URL=http://<server>:4000
NEXT_PUBLIC_REALTIME_URL=ws://<server>:4000/socket
```
**5. First-login smoke test:** request OTP (`POST /api/v1/auth/otp/request` with the phone) → **receive the SMS**
→ verify (`/api/v1/auth/otp/verify`) → create a conversation → send a message. The OTP send happens in the
**auth** container (SMSGatewayHub); `docker compose logs auth` shows the result (`ErrorCode 000` = sent).

**Going past a LAN/IP test (production):** put **Caddy/nginx** in front terminating HTTPS → `gateway:4000`, set
`PHX_HOST=<domain>` + `WEB_ORIGIN=https://<web-host>` in `.env`, and point the frontend at `https://<domain>` +
`wss://<domain>/socket`. Change the MinIO root creds from `minioadmin` (they're compose defaults) for anything
beyond a private test.

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
