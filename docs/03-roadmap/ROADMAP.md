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
- [~] Internal HTTP API per service (Plug endpoint exposing each service's functions via the shared internal result-envelope) + HTTP client adapters. **Auth template DONE (2026-06-18):** `SharedInfra.InternalApi` (result-envelope + atom-key rehydration, preserves error atoms) + `SharedInfra.InternalApi.TokenPlug` (internal `x-internal-token` auth, fails closed — new security surface) + `AuthService.HTTP.Router` (Plug, not Phoenix; gated `AUTH_HTTP_API_ENABLED`, default off → no listener at boot). Zero behavior change (215→227 plain, 283→295 pg). Contract: docs/09-devops/INTERNAL_API.md. **Conversation internal API DONE (2026-06-18):** `ConversationService.HTTP.Router` (gated `CONVERSATION_HTTP_API_ENABLED`, default off; 227→231 plain, 295→299 pg). **User internal API DONE (2026-06-18):** `UserService.HTTP.Router` (gated `USER_HTTP_API_ENABLED`, default off; 231→235 plain, 299→303 pg). Remaining: message/media internal APIs (copy the template), then HTTP client adapters flip `SharedInfra.*Client` to network behind a flag.
- [ ] Extract `shared_infra` to a shareable (git) dependency; services pin it.
- [ ] Per-service release + Dockerfile + runtime/config split.
- [ ] (optional) Database-per-service — split `010` init SQL, remove cross-service FKs (e.g. conversation_participants→users_auth).
- [ ] `docker-compose.prod.yml` wiring all containers + run as separate containers + cross-service integration tests + CI rework (per-service jobs + integration suite).
