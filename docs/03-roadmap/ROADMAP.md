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
- [ ] **Deploy blocker — OTP delivery (the remaining one):** no email/SMS channel exists; `request_otp` hashes + stores the code but never delivers it (and it's unrecoverable from the DB). A human can't log in until this is built (Swoosh + provider / SMS) or a flag-gated staging OTP-echo is added. Pairs with the Mailpit/gateway-full-path slice.
- [ ] **deploy 3b** — run a stack on a real host (Fly/VM), beyond local compose. Unblocked on schema-load; still gated on OTP delivery for a human login. `apps/backend/fly.toml` ready (set `app`/`PHX_HOST`, `fly secrets set`, `fly postgres attach`, `WEB_ORIGIN` once the web URL is known).
