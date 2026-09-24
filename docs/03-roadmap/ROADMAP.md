# Roadmap

## Phase 0: Documentation and Architecture

- [x] Create project folder
- [ ] Create docs folder structure
- [ ] Create AI_CONTEXT.md
- [ ] Create architecture overview
- [ ] Create service catalog
- [x] Create database design
- [x] Create Kafka event catalog
- [x] Create security model
- [x] Create local Docker setup plan

## Phase 1: Local Development Setup

- [x] Create Docker Compose setup
- [x] Add PostgreSQL
- [x] Add Redis
- [x] Add ScyllaDB
- [x] Add Kafka
- [x] Add MinIO
- [x] Add Mailpit
- [x] Add .env.example
- [x] Add PostgreSQL init schema
- [x] Add ScyllaDB message timeline schema
- [x] Add Kafka local topic setup

## Phase 2: Frontend Monorepo

- [ ] Create Nx workspace
- [ ] Create mobile app
- [ ] Create web app
- [ ] Create admin app
- [ ] Create business portal
- [ ] Create shared UI library
- [ ] Create API client library
- [ ] Create auth library
- [ ] Create chat-core library

## Phase 3: Backend Foundation

- [x] Create Phoenix backend base
- [x] Create API Gateway
- [x] Create Auth Service
- [x] Create User Service
- [x] Create Conversation Service
- [x] Create Message Service
- [x] Create Realtime Gateway
- [x] Install Elixir/Phoenix tooling locally
- [x] Run mix deps.get
- [x] Run mix format
- [x] Compile backend umbrella
- [x] Start Phoenix server locally
- [x] Verify API Gateway health check returns HTTP 200
- [x] Add shared infrastructure client behaviour foundation
- [x] Add PostgreSQL Sandbox test integration foundation

## Phase 4: Chat MVP

- [x] Define Auth Service API contract
- [x] Create Auth Service OTP boundary
- [x] Create Auth Service token boundary
- [x] Create Auth Service session boundary
- [x] Create Auth Service device boundary
- [x] Create Auth Service rate-limit boundary
- [x] Add Auth Service boundary test placeholders
- [x] Verify Auth Service foundation compile and tests
- [x] Add Auth Service PostgreSQL schema foundation
- [x] Add Auth Service persistence boundary tests
- [x] Add Auth Service OTP, token, refresh rotation, and rate-limit core helper foundation
- [x] Add DB-backed Auth OTP request persistence slice
- [x] Add DB-backed Auth OTP verify persistence slice
- [x] Add DB-backed Auth refresh token rotation slice
- [x] Add DB-backed Auth logout persistence slice
- [x] Add DB-backed Auth session endpoint slice
- [x] Expose Auth API skeleton routes through API Gateway
- [x] Add API Gateway Auth controller placeholder responses
- [x] Add API Gateway Auth controller tests
- [x] Verify Auth API Gateway skeleton compile and tests
- [x] Define User Service API contract
- [x] Create User Service profile boundary
- [x] Create User Service settings boundary
- [x] Create User Service privacy boundary
- [x] Add User Service PostgreSQL schema foundation
- [x] Add User Service persistence boundary tests
- [x] Expose User API skeleton routes through API Gateway
- [x] Add API Gateway User controller tests
- [x] Define Conversation Service API contract
- [x] Create Conversation Service conversation boundary
- [x] Create Conversation Service participant boundary
- [x] Create Conversation Service group boundary
- [x] Create Conversation Service permission boundary
- [x] Add Conversation Service PostgreSQL schema foundation
- [x] Add Conversation Service persistence boundary tests
- [x] Expose Conversation API skeleton routes through API Gateway
- [x] Add API Gateway Conversation controller tests
- [x] Define Message Service API contract
- [x] Create Message Service message boundary
- [x] Create Message Service receipt boundary
- [x] Create Message Service reaction boundary
- [x] Create Message Service timeline boundary
- [x] Create Message Service permission boundary
- [x] Add Message Service ScyllaDB query-plan foundation
- [x] Add Message Service persistence boundary tests
- [x] Expose Message API skeleton routes through API Gateway
- [x] Add API Gateway Message controller tests
- [x] Define Realtime Gateway WebSocket contract
- [x] Mount Realtime Gateway socket at API Gateway `/socket`
- [x] Create Realtime Gateway channel skeletons
- [x] Add Realtime Gateway channel tests
- [x] Add DB-aware Realtime Gateway join/message boundary
- [x] Review API skeleton consistency
- [x] Standardize API Gateway invalid-request error responses
- [x] Add shared Redis, Kafka, and ScyllaDB config helper foundation
- [x] Add opt-in PostgreSQL integration tests for Auth, User, and Conversation schemas
- [ ] User signup/login
- [ ] Create conversation
- [x] Send message (web creates over the realtime channel `message:create` when connected, HTTP fallback; persisted via Message Service under `MESSAGE_DB_BACKED`)
- [x] Receive message realtime (web subscribes to `message_created`; with web now creating over the channel, new text + media messages fan out to other clients live — metadata incl. `object_key` rides the payload)
- [x] Message durability (Postgres) — real persistence via `MessageStore.PostgresAdapter` behind `MESSAGE_STORE_ADAPTER=postgres` (create/list/edit/delete + media-metadata round-trip, pg-integration tested). Default adapters unchanged; plain `mix test` stays Docker-free
- [ ] Message list
- [ ] Delivery status
- [ ] Read receipt
- [ ] Typing indicator
- [ ] Online/offline presence
- [x] Message edit/delete UI (web) — incl. realtime propagation: `conversation_channel` now handles `message:update`/`message:delete` and broadcasts `message_updated`/`message_deleted`; the web edits/deletes over the channel (HTTP fallback) and patches other clients live
- [x] Author-only edit/delete enforcement — only the message sender may edit/delete, enforced at the shared `MessageService` boundary (covers HTTP `403 message.forbidden` + channel `realtime.forbidden`). Broader participant/tenant/block authz still TODO (Permissions placeholder)
- [x] HTTP message create/list membership enforcement — only active conversation participants may create/list messages over REST (`403 message.forbidden`), reusing the WS channel-join membership check; flag-gated on `CONVERSATION_DB_BACKED`. Block-state/tenant authz still TODO

## Phase 5: Media

- [x] Media upload boundary
- [x] Secure media URL boundary
- [ ] Image message (partial — web renders inline image preview from `metadata.content_type` + `metadata.object_key`; sending/persistence already work behind `MESSAGE_DB_BACKED`)
- [ ] Video message
- [ ] File message

## Phase 6: Calling

- [ ] Call signaling
- [ ] Incoming call
- [ ] Accept/reject call
- [ ] Audio call
- [ ] Video call
- [ ] Missed call notification

## Phase 7: Enterprise Features

- [ ] B2B organizations
- [ ] Roles and permissions
- [ ] Admin dashboard
- [ ] Audit logs
- [ ] Moderation
- [ ] Billing
- [ ] SSO later

## Phase 8: Scale Backends (future milestones)

- [ ] ScyllaDB live message backend — high-write message timeline persistence via a real
  CQL driver behind the existing `MessageStore` adapter (`MESSAGE_STORE_ADAPTER=scylla`).
  Deferred from the durability slice: blocked today by an ecto/decimal dependency conflict
  (Xandra needs `decimal ~> 2.0`, ecto pins `~> 3.0`). Durability currently runs on Postgres
  (`PostgresAdapter`). Revisit when write-scale justifies it or Xandra supports `decimal ~> 3.0`. See DECISION_LOG 2026-06-18.
- [ ] Kafka event production/consumption — IN PROGRESS: `message.created.v1` flows end-to-end producer→broker→consumer. Producer: `SharedInfra.Kafka.BrodProducer` (async, `:hash`, fire-and-forget, flag-gated, default `NoopProducer`). Consumers: (1) minimal `MessageService.Events.MessageCreatedLogConsumer` (`KAFKA_CONSUMER_ENABLED`, log/ack only); (2) **first stateful, idempotent consumer** `MessageService.Events.ConversationSummaryConsumer` (`KAFKA_PROJECTION_CONSUMER_ENABLED`, distinct group) maintaining the `conversation_message_summaries` projection, deduped via the `processed_events` ledger keyed `(consumer, event_id)`, exactly-once on redelivery, poison-skip on malformed events — this is the dedupe blueprint for notification-service. All flag-gated/default off. Verified live (`--include kafka_integration`) + exactly-once unit proof (`--include postgres_integration`). (3) **notification-service** `NotificationService.Events.MessageCreatedConsumer` (`NOTIFICATION_CONSUMER_ENABLED`, distinct group `notification-service-message-created`) — a SECOND service consuming the same topic, writing one notification record per event via its OWN ledger `notification_processed_events` (per-service ownership). Still pending: notification-service recipient fan-out (per-participant, needs ConversationService data) and the remaining ~40 catalog events
- [ ] Build the 5 documented-only services — **notification-service DONE (2026-06-18, first of 5)** as a new umbrella app (idempotent `message.created.v1` consumer; see DECISION_LOG). Remaining: tenant, call-signaling, moderation, audit.
- [ ] Recipient fan-out (event-driven cross-service data, NOT sync calls) — **(a) DONE:** ConversationService produces `participant_added`/`removed` (flag `CONVERSATION_PUBLISH_ENABLED`). **(b) DONE (2026-06-18):** notification-service consumes them into a local `conversation_participants_readmodel` (`ParticipantReadModel`, flag `NOTIFICATION_PARTICIPANTS_CONSUMER_ENABLED`) — idempotent (dedupe ledger) + out-of-order convergent (soft-state + occurred_at LWW). **(c) DONE (2026-06-18):** fan-out one notification per active recipient (excl. sender) via `Notifications.apply_message_created/1`, idempotent per `(source_event_id, recipient_user_id)` (UNIQUE index + `on_conflict: :nothing`); cold-start → notify nobody (accepted). **The full event-driven cross-service recipient flow is COMPLETE.** See DECISION_LOG 2026-06-18.

## Phase 9: Deployment & Observability (STARTED 2026-06-18)

- [x] **Sub-slice 1 — prod config + boot foundation:** Repos supervised at boot (gated `start_repo: false` in `:test` → plain `mix test` stays Docker-free); prod fail-fast secret guard (`SharedInfra.ProdConfig` in `config/runtime.exs` — refuses to boot on missing/placeholder `SECRET_KEY_BASE`/`TOKEN_SECRET`/`OTP_SECRET`); `config/prod.exs` + `config/runtime.exs` + `mix release` (`chat_platform`, all 8 apps). Fixes the "never run as a server" gap + audit #4. See [DEPLOYMENT.md](../09-devops/DEPLOYMENT.md) + DECISION_LOG 2026-06-18.
- [x] **Sub-slice 2 — containerize:** multi-stage `apps/backend/Dockerfile` (build `elixir:1.18.4-otp-27` + cmake/build-essential for brod's `crc32cer` NIF; runtime `debian:bookworm-slim`, ERTS bundled, non-root) + `.dockerignore`. Image builds (≈262 MB); the prod fail-fast guard fires in-container. No secrets baked in. See DEPLOYMENT.md + DECISION_LOG 2026-06-18.
- [~] Sub-slice 3 — deploy backend to Fly + managed Postgres (core chat ON, Kafka OFF). **3a DONE (2026-06-18):** `apps/backend/fly.toml` + ordered deploy runbook + debug-loop section in DEPLOYMENT.md (config inspection-validated; `runtime.exs` reads every Fly boot value). **3b (USER):** run `fly deploy` + apply schema (`001→042`) to managed PG + smoke-test — flyctl not available here, so the deploy is the user's step.
- [ ] Sub-slice 4 — baseline observability: structured (JSON) logs, request/correlation-id threading (replace `corr_placeholder`, tie request_id → event-envelope `correlation_id`), readiness `/health` (Repo check).
- [ ] Sub-slice 5 — deploy web (Vercel) pointed at the backend (`NEXT_PUBLIC_API_BASE_URL`/`NEXT_PUBLIC_REALTIME_URL`).
- [ ] Sub-slice 6 — provision managed Kafka, flip the producer/consumer flags, verify produce/consume/fan-out live.

## Phase 10: True microservices split (STARTED 2026-06-18, ~12-18 sub-slices)

Split the umbrella into separately-deployable service containers (network comms, not in-process). All cross-app coupling is at the EDGE apps (api_gateway, realtime_gateway); services are already event-decoupled. Enabling refactors run IN-UMBRELLA + flag-gated (suite stays green); actual container split is last. See DECISION_LOG 2026-06-18 + the Phase-1 inspection.

- [x] **Sub-slice 1 — service-client boundary (Auth):** `SharedInfra.AuthClient` (behaviour + dispatcher) + `AuthService.AuthClientInProcess` (default, in-process). Edge apps call `SharedInfra.AuthClient.*` (no `AuthService.*` left); a future `AUTH_CLIENT_ADAPTER=http` drops in without touching call sites. Zero behavior change (200→203 plain, 268→271 pg).
- [x] **Sub-slice 2 — service-client boundary (Conversation):** `SharedInfra.ConversationClient` + `ConversationService.ConversationClientInProcess` (default in-process). Edge apps (conversation_controller, message_controller membership authz, realtime topic_authorization) call `SharedInfra.ConversationClient.*` (no `ConversationService.*` left). Zero behavior change (203→205 plain, 271→273 pg).
- [x] **Sub-slice 3 — service-client boundary (User):** `SharedInfra.UserClient` + `UserService.UserClientInProcess` (default in-process). api_gateway/user_controller calls `SharedInfra.UserClient.*` (no `UserService.*` left). Zero behavior change (205→207 plain, 273→275 pg).
- [x] **Sub-slice 4 — service-client boundary (Message, heaviest seam):** `SharedInfra.MessageClient` + `MessageService.MessageClientInProcess` (default in-process). Both edges (message_controller + conversation_channel, 15 call-sites) call `SharedInfra.MessageClient.*` (no `MessageService.{Messages,Timeline,Receipts}.*` left). Zero behavior change (207→211 plain, 275→279 pg).
- [x] **Sub-slice 5 — service-client boundary (Media) — SET COMPLETE:** `SharedInfra.MediaClient` + `MediaService.MediaClientInProcess` (default in-process). api_gateway/media_controller calls `SharedInfra.MediaClient.*` (no `MediaService.Media.*` left). Zero behavior change (211→215 plain, 279→283 pg). **All 5 edge→service seams (Auth/Conversation/User/Message/Media) now go through `SharedInfra.*Client` — no edge app calls any `*Service.*` domain module directly.**
- [~] Internal HTTP API per service (Plug endpoint exposing each service's functions via the shared internal result-envelope) + HTTP client adapters. **Auth template DONE (2026-06-18):** `SharedInfra.InternalApi` (result-envelope + atom-key rehydration, preserves error atoms) + `SharedInfra.InternalApi.TokenPlug` (internal `x-internal-token` auth, fails closed — new security surface) + `AuthService.HTTP.Router` (Plug, not Phoenix; gated `AUTH_HTTP_API_ENABLED`, default off → no listener at boot). Zero behavior change (215→227 plain, 283→295 pg). Contract: docs/09-devops/INTERNAL_API.md. **Conversation internal API DONE (2026-06-18):** `ConversationService.HTTP.Router` (gated `CONVERSATION_HTTP_API_ENABLED`, default off; 227→231 plain, 295→299 pg). **User internal API DONE (2026-06-18):** `UserService.HTTP.Router` (gated `USER_HTTP_API_ENABLED`, default off; 231→235 plain, 299→303 pg). **Message internal API DONE (2026-06-18, heaviest 9 routes):** `MessageService.HTTP.Router` (gated `MESSAGE_HTTP_API_ENABLED`, default off; 235→240 plain, 303→308 pg). **Media internal API DONE (2026-06-18) — INTERNAL-API SET COMPLETE (all 5):** `MediaService.HTTP.Router` (gated `MEDIA_HTTP_API_ENABLED`, default off; 240→244 plain, 308→312 pg). **HTTP CLIENT adapter phase STARTED — Auth DONE (2026-06-23):** `SharedInfra.HttpClient` (shared helper; `:httpc` — Req unavailable offline, isolated for later swap) + `SharedInfra.AuthClientHttp` (flip via `AUTH_CLIENT_ADAPTER=http`+`AUTH_SERVICE_URL`; default in-process); gateway maps `:auth_unavailable`→503. 244→246 plain, 312→314 pg, `--include http_integration` 3 passed (real round-trip == in-process). **Conversation HTTP adapter DONE (2026-06-23):** `SharedInfra.ConversationClientHttp` (flip `CONVERSATION_CLIENT_ADAPTER=http`); gateway/realtime map `:conversation_unavailable`→503 at every call-site. 246→248 plain, 314→316 pg, conversation http_integration 3 passed. **User HTTP adapter DONE (2026-06-23):** `SharedInfra.UserClientHttp` (flip `USER_CLIENT_ADAPTER=http`); gateway maps `:user_unavailable`→503 (incl. fixing the public-profile no-catch-all crash). 248→249 plain, 316→317 pg, user http_integration 3 passed. **Message HTTP adapter DONE (2026-06-23):** `SharedInfra.MessageClientHttp` (9 callbacks; metadata caveat resolved via `decode_result/2 skip_atomize: ["metadata"]`); gateway→503 + realtime→unavailable. 249→254 plain, 317→322 pg, message http_integration 4 passed. **Media HTTP adapter DONE (2026-06-23) — CLIENT-ADAPTER SET COMPLETE (all 5):** `SharedInfra.MediaClientHttp` (flip `MEDIA_CLIENT_ADAPTER=http`); gateway→503. 254→255 plain, 322→323 pg, media http_integration 3 passed. All 5 `SharedInfra.*Client`s flip to HTTP behind their flag. Next phase: shared_infra extraction → per-service releases/Dockerfiles → docker-compose.prod → optional DB-per-service → CI rework.
- [x] ~~Extract `shared_infra` to a shareable (git) dependency~~ — **NOT NEEDED (decided 2026-06-23, mechanism iii):** Phase-1 inspection found shared_infra has ZERO compile-coupling to services, so per-service `mix release` from the monorepo achieves the split without a separate package (avoids a 2-repo edit→tag→bump workflow). shared_infra stays `in_umbrella`.
- [x] **Per-service releases + edge dep cleanup DONE (2026-06-23, packaging only — zero runtime change):** dropped the unused `{:*_service, in_umbrella}` deps from `api_gateway`/`realtime_gateway` mix.exs (all calls go via `SharedInfra.*Client`; this is the real decoupling — keeps the gateway image lean); added per-service releases to `apps/backend/mix.exs` (auth/user/conversation/message/media each `[<svc>, shared_infra]` + `gateway` `[api_gateway, realtime_gateway, shared_infra]`; kept all-in-one `chat_platform`). `mix test` 255/89 + pg 323 UNCHANGED; all 7 releases assemble; bundling lean (gateway = no service apps). notification_service per-service release pending (when containerized).
- [x] **Per-service Dockerfiles DONE (2026-06-23, build/config only — no app code):** ONE parameterized `apps/backend/Dockerfile` (`ARG RELEASE`, default `chat_platform` reproduces the all-in-one 3b image; `ARG SERVICE_PORT` for EXPOSE; `CMD exec /app/bin/$RELEASE_BIN start`). Each image bundles only its app + shared_infra. Verified WITH Docker: built `chat/auth_service` + `chat/gateway` (≈259 MB each); auth no-secrets → fail-fast guard; auth + dummy secrets + `AUTH_HTTP_API_ENABLED=true` → boots + listens (`:4101` → HTTP 401 `TokenPlug`). `mix test` 255/89 unchanged. Note: shared runtime.exs requires full prod env (incl. PHX_HOST) for every release — see DEPLOYMENT.md.
- [x] **`docker-compose.prod.yml` DONE (2026-06-23) — CORE SPLIT PROVEN LIVE ACROSS CONTAINERS:** repo-root compose, 7 containers (postgres + 5 services + gateway) on a shared `chatnet`; gateway flipped to HTTP adapters (`*_CLIENT_ADAPTER=http` + `*_SERVICE_URL=http://<svc>:<port>`); services on `*_HTTP_API_ENABLED=true` + `*_DB_BACKED`; one shared Postgres; schema auto-applied via `infra/docker/postgres/init`→`/docker-entrypoint-initdb.d` (001..042). Kafka/Redis/Scylla/MinIO intentionally OFF (staged). Verified WITH Docker: all images build; `up -d` → 7/7 running; `/health` 200; 36 tables; cross-network proof — gateway→auth session→401, STOP auth→503 `auth.unavailable`, RESTART→401 (auto-recovery). `mix test` 255/89 unchanged. Runbook + debug loop: DEPLOYMENT.md. The microservices split now runs as separate containers, gateway talking over the network. (notification_service container + full OTP/message round-trip [needs email channel] + MinIO still to wire.)
- [ ] (optional) Database-per-service — split `010` init SQL, remove cross-service FKs (e.g. conversation_participants→users_auth). **Deferred** (cross-service FKs).
- [x] **CI rework Layer 2 DONE (2026-06-23):** added an `integration` job to `.github/workflows/backend-ci.yml` (parallel to the UNCHANGED fast Docker-free `backend` gate) — `postgres:16` service container, loads ALL `infra/docker/postgres/init/*.sql` (001..042), runs `mix test --include postgres_integration --include http_integration`. Locks the DB suite (323) + the 5 HTTP adapters' round-trips into CI. Fixed the stale LOCAL_DEV_SETUP.md (load all init SQL, not just 010). Proof = the Actions run.
- [x] **CI rework Layer 3 DONE (2026-06-24):** gated `compose-integration` job in `.github/workflows/backend-ci.yml` (runs only on `workflow_dispatch` + nightly `schedule` + PR label `ci:compose`; `timeout-minutes: 30`; `up -d --build --wait` → `scripts/ci/compose_differential.sh` → `if: always()` `down -v`). The committed script asserts the gateway→auth contract over the live `docker-compose.prod.yml` network: 401 `auth.session_invalid` (auth up) → 503 `auth.unavailable` (auth stopped, gateway alive) → 401 (recovery). Local end-to-end PASS (all 3 states); fast `backend` + `integration` jobs untouched; `mix test` 255/89 Docker-free unchanged. Heavy build → gated off the per-push path.
- [ ] (later) Per-service / per-release CI matrix — deferred until repos or release cadences diverge.
- [x] **Observability — correlation_id end-to-end + prod JSON logs DONE (2026-06-24):** one id traces gateway → internal HTTP → 5 services → Kafka envelope → consumers. `ApiGatewayWeb.Plugs.CorrelationId` (honor inbound `x-correlation-id` else mint; real id in the error envelope, `corr_placeholder` removed) + `SharedInfra.Correlation` (`:crypto`, no ecto) + `CorrelationPlug` on all 5 routers + `http_client` sends the header + producers sync-capture before the async Kafka Task + 4 consumers set Logger metadata + prod-only hand-rolled `JsonFormatter` (no dep). Adversarial review (6 dims) 5/6 zero findings; 2 test gaps fixed. 273/91 plain, 359/0 integration, zero `corr_placeholder` in source. See DECISION_LOG [2026-06-24].
- [x] ~~**DEFERRED — Kafka consumer correlation→metadata regression guards**~~ **DONE (2026-06-24):** all 4 consumers emit `{:consumer_correlation, Correlation.get()}`; 3 consumer `kafka_integration` tests assert it (pinned) — 3/3 over a live broker. Closed as part of the Kafka-into-compose slice.
- [x] **Kafka event-backbone + notification_service into compose DONE (2026-06-24):** `docker-compose.prod.yml` gains `kafka` (KRaft, internal-only, healthcheck; `bitnamilegacy` revisit-TODO) + `kafka-init` (topics at declared partition counts via topics.env — not AUTO_CREATE; `:hash` keying needs a stable count) + `notification` container (RELEASE=notification_service, consumer flags, `depends_on postgres+kafka-init`, no port — pure consumer). message/conversation get `KAFKA_PRODUCER_ADAPTER=brod` + publish flags + `KAFKA_BROKERS=kafka:9092` (publish-enabled alone leaves NoopProducer; adapter=brod required to emit). Added the notification_service per-service release. Live e2e: participant_added→read-model→message.created→**1 notification row for the recipient, sender excluded** (real fan-out through containers); fast gate 273/91 unchanged. See DECISION_LOG [2026-06-24].
- [x] **MinIO into compose DONE (2026-06-24) — COMPOSE STACK FEATURE-COMPLETE:** added `minio` (internal-only, curl healthcheck, `minio_data` vol) + `minio-init` (creates the `chat-media` bucket via the image's bundled `mc` — the dev compose didn't) + flipped media to `MEDIA_STORAGE_ADAPTER=minio` (endpoint `http://minio:9000`, bucket `chat-media`, path-style), `depends_on` postgres healthy + minio-init completed. Live e2e: `mc cp`/`cat` round-trip against `chat-media` byte-identical; media booted with MinioAdapter. Fast gate 273/91 unchanged. The stack is now postgres + 5 services + gateway + kafka/kafka-init/notification + minio/minio-init. See DECISION_LOG [2026-06-24]. (Authed gateway→media→MinIO upload path deferred to the Mailpit slice; covered by media presign unit tests.)
- [ ] **Known follow-up — JsonFormatter charlist metadata:** brod emits some metadata (e.g. `file`) as charlists → rendered as int arrays (valid JSON, key fields clean; cosmetic). Add a printable-charlist heuristic if desired.
- [ ] **Known follow-up — gateway→broker→notification full path:** not yet exercised end-to-end (direct broker produce used; the gateway-authed message path needs OTP/Mailpit). Covered today by `kafka_integration` producer + unit tests; full path deferred to a Mailpit slice.
- [x] **Deploy blocker — schema load on a managed DB DONE (2026-06-24):** `SharedInfra.Release.load_schema/0` (run via `bin/chat_platform eval`) applies the raw SQL (`priv/schema/*.sql`, a release-bundled drift-guarded copy of `infra/docker/postgres/init`) against `DATABASE_URL` via Postgrex — the managed PG comes empty + the slim image has no `psql`. Idempotent. Proven against a throwaway empty `postgres:16`: 0→36 tables, ordered, idempotent re-run. Deploy order: provision PG → secrets + `postgres attach` → `eval load_schema()` → boot. See DECISION_LOG [2026-06-24].
- [x] **Deploy blocker — OTP delivery DONE (2026-06-24) — both deploy blockers now closed:** `AuthService.SmsClient` (Req → SMSGatewayHub `/api/mt/SendSMS`, DLT template "Dear user, your login OTP is #{code} 1500BC", ErrorCode 000=success) + `AuthService.OtpDelivery` (hooked into `request_persisted_otp` after persist; SMS-when-enabled, email no-op, resilient — failure logged, OTP still persisted) + `config :auth_service, :sms` (default OFF via `OTP_SMS_DELIVERY_ENABLED`; secrets env-only). Flag-gated, default-off; tests stub Req (real provider never called) — 281/91. A human can log in once the flag is on + SMS secrets set. ⚠️ app generates 6-digit OTPs — confirm the DLT LOGIN template accepts 6. Email = separate future channel. See DECISION_LOG [2026-06-24].
- [x] **Demo/echo OTP for local testing DONE (2026-06-24):** `OTP_DELIVERY_MODE` env (default `"none"`, prod-safe) — `"echo"` returns the code in the OTP-request response (`debug_code`), `"log"` logs it; independent of `OTP_SMS_DELIVERY_ENABLED`, so a local demo = SMS off + `OTP_DELIVERY_MODE=echo` (no real phone needed). LOUD once-per-VM `Logger.error` guard if `:prod` + echo/log. Default unchanged (284/91). See DECISION_LOG [2026-06-24]. (Local-test convenience; production uses `none` + real SMS.)
- [~] **deploy 3b** — run a stack on a real host. **Both code blockers closed** (schema-load + OTP) AND **host config is now `.env`-driven** (2026-06-24): `docker-compose.prod.yml` `PHX_HOST`/`WEB_ORIGIN`/SMS envs are env-driven (no per-deploy compose edits), and a **self-hosted runbook** is in DEPLOYMENT.md. Remaining = **operator action**: provision a Linux box (≥4 GB RAM, Docker+Compose v2), fill `.env` (4 secrets + `PHX_HOST` + SMS block), `docker compose -f docker-compose.prod.yml up -d --build`, deploy `apps/web` with the API/WS URLs, do the first real login. Pre-flight: confirm the DLT LOGIN template accepts a 6-digit OTP + rotate the SMS key. (Fly path also ready via `apps/backend/fly.toml` + `load_schema` for the managed-PG empty DB.)
- [ ] **WEB SLICE — message requests bucket + Accept/Decline in `apps/web`:** Android and iOS both ship a requests bucket calling `POST /api/v1/conversations/:id/request/accept|decline`; `apps/web` ships neither, so a web recipient can see a pending request but has no way to answer it. Needs: the `scope=requests` inbox listing, an Accept and a Decline action against the two existing endpoints, and the main list filtered to exclude pending rows. The 130 implicit accept (a recipient's reply accepts the request) removes the dead end — a web user who replies is now accepted — but it is a safety net, not the feature: declining, and accepting without replying, still have no web UI.
- [ ] **Scylla has no backup:** `pg_dump` covers Postgres only, and messages are Scylla-authoritative in prod (`MESSAGE_STORE_ADAPTER=scylla`), so every predeploy dump to date contains zero messages and a "full restore" would return accounts and conversations with no history. Plan drafted in `docs/deploy/2026-09-23.md` (Follow-up 1): `nodetool snapshot` + schema `DESCRIBE` + copy off-box + `clearsnapshot`, rather than a tar of a running volume. Open: snapshot-path resolution, off-box destination (the Postgres dumps are not off-box either), retention, restore method, and a restore rehearsal against a throwaway keyspace.
- [ ] **Maintenance reboot — the box reports `System restart required`:** the running kernel keeps the unpatched code until a reboot. Plan in `docs/deploy/2026-09-23.md` (Follow-up 2). The thing to fix first: there is no `stop_grace_period` anywhere in `docker-compose.prod.yml`, so Postgres, Scylla and Kafka get Docker's default 10 s before SIGKILL — thin enough to mean WAL/commitlog replay or worse. Raise it for those three (a recreate; fold into the same window) rather than relying on a manual `stop --timeout 60`, because an unplanned reboot gets no such courtesy.
- [ ] **`assetlinks.json` is missing Google's app-signing SHA-256:** only one fingerprint is served (`A3:CE:01:…`), which `infra/caddy/Caddyfile` records as the RELEASE KEYSTORE's. Under Play App Signing Google re-signs the upload with a different key, so the installed APK carries Google's fingerprint and Android App Links verification fails for every Play-installed build — deep links fall back to the chooser with no server-side error, the endpoint keeps serving 200. Fix: Play Console → Release → Setup → App signing → copy the *App signing key certificate* SHA-256 and add it **alongside** the existing one (the list keeps locally-built release APKs verifying). Confirm with `digitalassetlinks.googleapis.com/v1/statements:list?source.web.site=https://web.growblic.com&…`. Needs a Play Console value, so it was not done in the 2026-09-23 window; see `docs/deploy/maintenance-window.md`.
- [ ] **iOS parity sweep — VoIP push needs a send timestamp or `apns-expiration`:** a call push delivered late (device offline, network stall) currently rings a call that has already ended, because nothing in the payload or the APNs headers says when it was sent or when it stops being worth delivering. Add either a send timestamp the client compares against the ring timeout, or `apns-expiration` so APNs itself drops a stale one — probably both, since expiration protects the un-launched app and the timestamp protects the launched one. Touches `NotificationService.ApnsSender`'s VoIP path. A VoIP push that cannot be answered is worse than none: iOS requires the app to report a call to CallKit on every VoIP wake, so a stale push forces a phantom ring.
- [ ] **iOS parity sweep — change-number endpoint:** no way to move an account to a new phone number. Needs OTP verification of the NEW number, a uniqueness check against live accounts (the partial index means a tombstoned number is free), and a decision on what the peers see — WhatsApp posts a system message into shared chats. Interacts with account deletion (130): both rewrite `users_auth.phone_number`, so the re-auth guard and the tombstone's NULL-phone path must stay consistent.
- [ ] **iOS parity sweep — "who can add me to groups" privacy setting:** a per-user preference (`everyone` / `contacts` / `nobody`, matching the existing `last_seen_visibility` shape) enforced at BOTH group create and add-member, server-side — not a client-side filter. Note the contacts problem: contacts are deliberately not a server signal (`/contacts/sync` persists nothing), so `contacts` here has to mean the same thing `shares_conversation?` means for presence, or the setting needs a different middle value. Decide that before building it.
- [ ] **iOS parity sweep — conversation-less call start for ad-hoc group calls** *(pending confirmation from iOS that it is missing)*: starting a call with a set of users who have no existing conversation. Today the call path assumes a conversation id. Either create the conversation implicitly at call start, or let a call carry a participant set of its own. The first is simpler and matches how a first message already works; the second avoids littering the inbox with conversations nobody wanted. Confirm the gap with iOS before choosing.
- [ ] **Group calls — server half is incomplete (one slice; from the iOS Batch 3 audit at `origin/main` `13992f0`, each item re-verified at file:line on 2026-09-23). Don't build piecemeal — the five gaps share one design question: what a group call's per-participant state is, and who gets told when.**
  - **(a) `GET /api/v1/calls/:id` is 404 for every group, link and adhoc invitee.** `call_controller.ex` has TWO participant checks that expect different shapes: `authorized_for_call?/3` (:150-161, the `/calls/token` path) matches `%{authorized: true}` — and its string-key twin — correctly; `ensure_party/2` (:213-224, the `show` path) calls `call_participant?/2` (:226-232), which matches `%{participant: true}`. `call_store.ex` `call_participant?` returns `{:ok, %{authorized: boolean}}` (:588-599), so the `show` helper never matches and `ensure_party` falls to `{:error, :forbidden}`, which `show` deliberately maps to 404 `calls.not_found` (:39, no-existence-leak). Net: a group invitee can mint a LiveKit token but cannot read the call — including the sealed `e2ee_offer` the push-woken path (§11 of E2EE_FRAME) exists to fetch. Fix is one helper reusing the working shape (and tolerating the string key, as the working one does) plus a test with a `kind: "group"` invitee.
  - **(b) `mark_answered/1` is a single-callee transition.** `call_store.ex:70-84` flips the ONE call row to `status: "accepted"` with one `answered_at` (and the 1:1 `e2ee_accepted`); there is no per-participant answered state on that row, so the REST accept path cannot mean "this member joined". Group joins today live on `group_call_participants` via the socket (`call:participant_joined`); the REST and socket models need reconciling before a REST group accept can exist.
  - **(c) Incoming PUSH exists only for direct calls.** `call.incoming` (the Kafka event `notification_service/events/call_incoming_consumer.ex:41` turns into FCM/APNs-VoIP) is produced only by `emit_incoming_push` (`call_signaling.ex:1179`), whose sole caller is `ring_callee` (:170). The group ring (:348-372) and the adhoc ring (:426-450) do a socket `broadcast` of `call:group_incoming` and nothing else. A group member whose app is closed or backgrounded gets no push, no VoIP ring, and — after the 35 s `group_ring_timeout` (:370, :448, :837) — a "Missed group call" pill for a call they were never told about.
  - **(d) No REST group decline** — `POST /api/v1/calls/:id/reject` (`router.ex:482`) is callee-only by design (the closed-app 1:1 case); a group member with no socket cannot decline, which (c) makes the common case. **No group-call E2EE** — sender keys deferred (§10.7 / parked). **No stale-call reaper** — the ring timeouts cover un-answered calls only; an accepted call nobody hangs up stays `accepted` forever (no sweep on `answered_at`). **No docs contract** — `docs/05-api-contracts/` has no calls file; the group events exist only in Android's `ANDROID_API_CONTRACT.md` (§"Group-call events", verified 2026-07-24) and iOS's `CONTRACTS.md`.
  - **(e) Ad-hoc (conversation-less) calls share the no-ring gap** — `call:adhoc_invite` (:388-459) rings over the socket via the same `call:group_incoming` broadcast and the same `group_ring_timeout`, with no push; so an ad-hoc invitee who is not already connected never rings. (The rate limits at :401-404 are fine.)
  - **Android today:** (c) and (e) **hit Android now** — it does all group calling over the socket events (`call:group_incoming`, `participant_*`, `promoted`, `group_ended`) and has FCM only for `call.incoming`, so a closed/backgrounded Android member misses every group and ad-hoc call. (a) does **not** hit Android today: its contract never calls `GET /calls/:id` (it uses `call:group_incoming` + `POST /calls/token` + socket/REST reject). (b) does not hit Android (group joins go over the socket). (d): Android declines groups over the socket, so it only bites when there is no socket — i.e. exactly (c)'s case. Web: has `GroupCallBanner`/`CallProvider` for socket group rings and does fetch `getCallState` (`api.ts`), so (a) hits web for group calls the same way it hits iOS.
  - **Order when built:** (a) first (one-line, unblocks iOS/web reads); then the (b)+(c)+(d) design as one piece — a per-participant state that both REST and socket write, `call.group_incoming` produced beside the socket broadcast so the existing push consumer can fan it out per member (VoIP on iOS needs the `apns-expiration`/timestamp item above, or a late group push rings an ended call), a REST decline that writes `participant_declined`; then the reaper; then the contract doc, written from the code.
- [x] **DONE (Android `cf4d4fd`, 23 Sep) — "Add member" is now owner-only.** Was: offered to every member while the server allowed only the owner. `add_call_participant`/group membership adds are owner-gated server-side, so a plain member taps Add, gets a refusal, and the UI has told them a lie first. Match the server: show the action only when the session user is the group owner (read the role the server already returns), and treat a server refusal as the source of truth, not the button.
- [ ] **Android — retest live-location STOP after `b83b401` deploys.** Under `MESSAGE_STORE_ADAPTER=scylla` a metadata patch ran the body-edit plan, so a stop came back `status:"edited"`, `body:null`, still live, and `ended_at` was never stored (iOS Batch 5 audit; affects Android identically — the only sender of `metadata_patch` is the shared socket live-location handler). Fixed server-side with a metadata-mode plan on the Scylla adapter (Scylla integration test + adapter parity). On the device: share live location, stop, kill and reopen the app — the bubble must show ended, and a fresh fetch must carry `ended_at` with `live:"false"`.
- [x] **iOS Slice 16 DONE (`8bdd03c`)** — simulator work complete. What remains on iOS is not simulator work: **(7b)** needs the paid team (real bundle id, entitlements, APNs/VoIP, NSE sealed decrypt, `applinks:web.growblic.com`, TestFlight); the **real-iPhone batch** (camera, CallKit UI, Face ID, voice, translate/transcribe, Android↔iOS E2EE, live receive, deletion on `+15550199004`); and three items **waiting on the backend**: live-location stop (`b83b401`, deploys tonight), the group push flag (`CALL_GROUP_PUSH_ENABLED` — stays off until Android and iOS branch on `kind`), and view-once "Opened" sync.
