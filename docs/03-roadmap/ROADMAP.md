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
- [ ] Kafka event production/consumption — IN PROGRESS: `message.created.v1` reaches a real broker via the **brod-backed producer adapter** (`SharedInfra.Kafka.BrodProducer`, `KAFKA_PRODUCER_ADAPTER=brod`, async + `:hash`, flag-gated client; default `NoopProducer`), fire-and-forget; verified live (`--include kafka_integration`). Still pending: the **consumer side** and the remaining ~40 catalog events
