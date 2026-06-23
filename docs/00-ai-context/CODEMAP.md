# Codemap

## Purpose

This file explains where important code lives so AI and developers do not need to scan the whole repository repeatedly.

## Important Context Files

- docs/00-ai-context/AI_CONTEXT.md
- docs/00-ai-context/CODEMAP.md
- docs/00-ai-context/SESSION_LOG.md
- docs/03-roadmap/ROADMAP.md
- docs/04-services/SERVICE_CATALOG.md
- docs/11-decisions/DECISION_LOG.md

## Root

```txt
chat-platform/
  AGENTS.md
  README.md
  apps/
    backend/
      mix.exs
      config/
      apps/
        api_gateway/
        auth_service/
        user_service/
        conversation_service/
        message_service/
        realtime_gateway/
        shared_infra/
    frontend/
  docs/
  infra/
    docker/
```

## Backend

```txt
apps/backend/
  mix.exs
  README.md
  config/
    config.exs
    dev.exs
    test.exs        # sets `start_repo: false` for the 5 Repo apps → Docker-free test boot
    prod.exs        # minimal prod compile-time config
    runtime.exs     # prod-only: fail-fast secret guard + Repo/Endpoint/Kafka wiring from env
  mix.exs           # `releases: [chat_platform: ...]` — umbrella release of all 8 apps
  apps/
    api_gateway/
    auth_service/
    user_service/
    conversation_service/
    message_service/
    realtime_gateway/
    shared_infra/
```

### api_gateway

Phoenix HTTP entry point for external clients.

Important files:

- `apps/backend/apps/api_gateway/lib/api_gateway/application.ex`
- `apps/backend/apps/api_gateway/lib/api_gateway_web/endpoint.ex`
- `apps/backend/apps/api_gateway/lib/api_gateway_web/router.ex`
- `apps/backend/apps/api_gateway/lib/api_gateway_web/controllers/error_response.ex`
- `apps/backend/apps/api_gateway/lib/api_gateway_web/controllers/health_controller.ex`
- `apps/backend/apps/api_gateway/lib/api_gateway_web/controllers/auth_controller.ex`
- `apps/backend/apps/api_gateway/lib/api_gateway_web/controllers/user_controller.ex`
- `apps/backend/apps/api_gateway/lib/api_gateway_web/controllers/conversation_controller.ex`
- `apps/backend/apps/api_gateway/lib/api_gateway_web/controllers/message_controller.ex`
- `apps/backend/apps/api_gateway/test/api_gateway_web/controllers/auth_controller_test.exs`
- `apps/backend/apps/api_gateway/test/api_gateway_web/controllers/auth_controller_postgres_integration_test.exs`
- `apps/backend/apps/api_gateway/test/api_gateway_web/controllers/user_controller_test.exs`
- `apps/backend/apps/api_gateway/test/api_gateway_web/controllers/conversation_controller_test.exs`
- `apps/backend/apps/api_gateway/test/api_gateway_web/controllers/message_controller_test.exs`

Current endpoint:

- `WebSocket /socket`
- `GET /health`
- `POST /api/v1/auth/otp/request`
- `POST /api/v1/auth/otp/verify`
- `POST /api/v1/auth/refresh`
- `POST /api/v1/auth/logout`
- `GET /api/v1/auth/session`
- `GET /api/v1/users/me`
- `PATCH /api/v1/users/me`
- `GET /api/v1/users/:user_id/profile`
- `POST /api/v1/conversations`
- `GET /api/v1/conversations`
- `GET /api/v1/conversations/:conversation_id`
- `POST /api/v1/conversations/:conversation_id/participants`
- `DELETE /api/v1/conversations/:conversation_id/participants/:user_id`
- `POST /api/v1/conversations/:conversation_id/messages`
- `GET /api/v1/conversations/:conversation_id/messages`
- `PATCH /api/v1/conversations/:conversation_id/messages/:message_id`
- `DELETE /api/v1/conversations/:conversation_id/messages/:message_id`
- `POST /api/v1/conversations/:conversation_id/messages/:message_id/read`
- `POST /api/v1/conversations/:conversation_id/messages/:message_id/delivered`

Current behavior:

- REST controllers return contract-aligned placeholder success responses.
- Auth OTP verify maps database-backed OTP failures to the contract-aligned
  `auth.otp_invalid` 401 error when the opt-in verify path is enabled.
- Auth refresh maps database-backed refresh failures to the contract-aligned
  `auth.refresh_invalid` 401 error when the opt-in refresh path is enabled.
- Auth logout maps invalid or already-revoked refresh tokens to
  `auth.refresh_invalid` 401 when the opt-in logout path is enabled.
- Auth session maps missing/invalid signed-envelope access tokens and invalid
  DB session state to `auth.session_invalid` 401 when the opt-in session path is enabled.
- HTTP message create/list gate on conversation membership (`message_controller.ex` `authorize_membership/2` → `ConversationService.Conversations.get_conversation/1`); non-participants get `403 message.forbidden` when conversation persistence is enabled.
- Invalid REST payloads use the shared `ApiGatewayWeb.ErrorResponse` shape with `error.code`, `error.message`, and `error.correlation_id`.

### auth_service

Authentication service shell.

Important files:

- `apps/backend/apps/auth_service/lib/auth_service/application.ex`
- `apps/backend/apps/auth_service/lib/auth_service/repo.ex`
- `apps/backend/apps/auth_service/lib/auth_service/otp.ex`
- `apps/backend/apps/auth_service/lib/auth_service/tokens.ex`
- `apps/backend/apps/auth_service/lib/auth_service/sessions.ex`
- `apps/backend/apps/auth_service/lib/auth_service/devices.ex`
- `apps/backend/apps/auth_service/lib/auth_service/rate_limits.ex`
- `apps/backend/apps/auth_service/lib/auth_service/accounts.ex`
- `apps/backend/apps/auth_service/lib/auth_service/verification_codes.ex`
- `apps/backend/apps/auth_service/lib/auth_service/device_sessions.ex`
- `apps/backend/apps/auth_service/lib/auth_service/refresh_tokens.ex`
- `apps/backend/apps/auth_service/lib/auth_service/login_attempts.ex`
- `apps/backend/apps/auth_service/lib/auth_service/schemas/user_auth.ex`
- `apps/backend/apps/auth_service/lib/auth_service/schemas/verification_code.ex`
- `apps/backend/apps/auth_service/lib/auth_service/schemas/device_session.ex`
- `apps/backend/apps/auth_service/lib/auth_service/schemas/refresh_token.ex`
- `apps/backend/apps/auth_service/lib/auth_service/schemas/login_attempt.ex`
- `apps/backend/apps/auth_service/test/support/data_case.ex`
- `apps/backend/apps/auth_service/test/auth_service/auth_core_test.exs`
- `apps/backend/apps/auth_service/test/auth_service/postgres_integration_test.exs`
- `apps/backend/apps/auth_service/test/auth_service/persistence_schemas_test.exs`
- `apps/backend/apps/auth_service/test/auth_service/persistence_boundaries_test.exs`

Current contract:

- `docs/05-api-contracts/auth-service.md`

Current behavior:

- Auth boundary functions return contract-aligned placeholder responses for API Gateway skeleton endpoints.
- Auth OTP request can persist hashed `verification_codes` rows when DB-backed OTP request persistence is enabled.
- Auth OTP verify can validate stored OTP hashes, reject expired/consumed codes, find or create `users_auth`, consume the verification code, create/update `device_sessions`, and store only hashed refresh tokens when DB-backed OTP verify persistence is enabled.
- Auth refresh can hash presented refresh tokens, reject missing/revoked/expired/device-mismatched records, revoke the old token, create a new hashed refresh-token record, and update the device session when DB-backed refresh persistence is enabled.
- Auth logout can hash presented refresh tokens, reject missing/already-revoked records, revoke active refresh tokens, and set the associated device session `revoked_at` when DB-backed logout persistence is enabled.
- Auth session can validate the existing signed-envelope access-token helper, load `device_sessions`, verify active `users_auth`, reject revoked sessions, and return contract-aligned session data when DB-backed session persistence is enabled.
- Auth has offline-safe OTP code generation, OTP HMAC hashing/verification, signed access-token envelope helpers, refresh-token hashing/rotation planning helpers, and Redis rate-limit key/policy planning helpers.
- Auth persistence schemas and data-access boundaries exist for `users_auth`, `verification_codes`, `device_sessions`, `refresh_tokens`, and `login_attempts`.
- Auth has opt-in PostgreSQL Sandbox integration test support tagged `:postgres_integration`.
- No real OTP delivery, production JWT signing, JWT blacklist, Redis-backed rate-limit execution, Kafka publishing, or cross-service authorization exists yet.
- Explicit verification-code revocation needs a future schema migration because `verification_codes` has no `revoked_at` column yet.

### user_service

User profile service shell.

Important files:

- `apps/backend/apps/user_service/lib/user_service/application.ex`
- `apps/backend/apps/user_service/lib/user_service/repo.ex`
- `apps/backend/apps/user_service/lib/user_service/profiles.ex`
- `apps/backend/apps/user_service/lib/user_service/settings.ex`
- `apps/backend/apps/user_service/lib/user_service/privacy.ex`
- `apps/backend/apps/user_service/lib/user_service/profile_store.ex`
- `apps/backend/apps/user_service/lib/user_service/settings_store.ex`
- `apps/backend/apps/user_service/lib/user_service/privacy_store.ex`
- `apps/backend/apps/user_service/lib/user_service/schemas/user_profile.ex`
- `apps/backend/apps/user_service/lib/user_service/schemas/user_settings.ex`
- `apps/backend/apps/user_service/lib/user_service/schemas/user_privacy_settings.ex`
- `apps/backend/apps/user_service/test/support/data_case.ex`
- `apps/backend/apps/user_service/test/user_service/postgres_integration_test.exs`
- `apps/backend/apps/user_service/test/user_service/boundaries_test.exs`
- `apps/backend/apps/user_service/test/user_service/persistence_schemas_test.exs`
- `apps/backend/apps/user_service/test/user_service/persistence_boundaries_test.exs`

Current contract:

- `docs/05-api-contracts/user-service.md`

Current behavior:

- User boundary functions return contract-aligned placeholder responses for API Gateway skeleton endpoints.
- User persistence schemas and data-access boundaries exist for `user_profiles`, `user_settings`, and `user_privacy_settings`.
- User has opt-in PostgreSQL Sandbox integration test support tagged `:postgres_integration`.
- No real authentication middleware, API flow persistence, database-backed profile logic, or search exists yet.

### conversation_service

Conversation metadata service shell.

Important files:

- `apps/backend/apps/conversation_service/lib/conversation_service/application.ex`
- `apps/backend/apps/conversation_service/lib/conversation_service/repo.ex`
- `apps/backend/apps/conversation_service/lib/conversation_service/participant_events.ex`
- `apps/backend/apps/conversation_service/lib/conversation_service/conversations.ex`
- `apps/backend/apps/conversation_service/lib/conversation_service/participants.ex`
- `apps/backend/apps/conversation_service/lib/conversation_service/groups.ex`
- `apps/backend/apps/conversation_service/lib/conversation_service/permissions.ex`
- `apps/backend/apps/conversation_service/lib/conversation_service/conversation_store.ex`
- `apps/backend/apps/conversation_service/lib/conversation_service/participant_store.ex`
- `apps/backend/apps/conversation_service/lib/conversation_service/conversation_settings_store.ex`
- `apps/backend/apps/conversation_service/lib/conversation_service/group_profile_store.ex`
- `apps/backend/apps/conversation_service/lib/conversation_service/schemas/conversation.ex`
- `apps/backend/apps/conversation_service/lib/conversation_service/schemas/conversation_participant.ex`
- `apps/backend/apps/conversation_service/lib/conversation_service/schemas/conversation_settings.ex`
- `apps/backend/apps/conversation_service/lib/conversation_service/schemas/group_profile.ex`
- `apps/backend/apps/conversation_service/test/support/data_case.ex`
- `apps/backend/apps/conversation_service/test/conversation_service/postgres_integration_test.exs`
- `apps/backend/apps/conversation_service/test/conversation_service/boundaries_test.exs`
- `apps/backend/apps/conversation_service/test/conversation_service/persistence_schemas_test.exs`
- `apps/backend/apps/conversation_service/test/conversation_service/persistence_boundaries_test.exs`

Current contract:

- `docs/05-api-contracts/conversation-service.md`

Current behavior:

- Conversation boundary functions return contract-aligned placeholder responses for API Gateway skeleton endpoints.
- Conversation persistence schemas and data-access boundaries exist for `conversations`, `conversation_participants`, `conversation_settings`, and `group_profiles`.
- Conversation has opt-in PostgreSQL Sandbox integration test support tagged `:postgres_integration`.
- **Kafka producer (2026-06-18):** `ConversationService.ParticipantEvents` emits `conversation.participant_added.v1` `{conversation_id, user_id, role, added_by}` and `conversation.participant_removed.v1` `{conversation_id, user_id, removed_by}` to `conversation.events.v1` (key `conversation_id`) via `SharedInfra.Kafka.Producer`, fire-and-forget (flag `CONVERSATION_PUBLISH_ENABLED`, default off, `Task.start`, try/rescue/catch — mirrors `MessageService.Messages.publish_message_created`). Emitted from ALL THREE membership points: conversation creation (one `participant_added` per initial participant, after the tx commits — `conversations.ex`), `Participants.add_participant`, `Participants.remove_participant`. `ConversationService.Application` starts its OWN brod client (`:conversation_service_kafka_client`) ONLY when the brod adapter is selected AND `CONVERSATION_PUBLISH_ENABLED` (default off ⇒ `children/0 == []` ⇒ Docker-free). `SharedInfra.Kafka.BrodProducer` now selects the client per-call via `opts[:client]` (default = message-service client, unchanged). This sets the participant-event contract that notification-service's read-model (sub-slice b) will consume. NO consumer/read-model/fan-out here yet.
- Beyond the producer above, no real authentication middleware, broader authorization checks, or API flow persistence beyond the DB-backed conversation/participant logic exists yet.

### message_service

Message timeline service shell.

Important files:

- `apps/backend/apps/message_service/lib/message_service/application.ex`
- `apps/backend/apps/message_service/lib/message_service/infrastructure.ex`
- `apps/backend/apps/message_service/lib/message_service/messages.ex`
- `apps/backend/apps/message_service/lib/message_service/receipts.ex`
- `apps/backend/apps/message_service/lib/message_service/reactions.ex`
- `apps/backend/apps/message_service/lib/message_service/timeline.ex`
- `apps/backend/apps/message_service/lib/message_service/permissions.ex`
- `apps/backend/apps/message_service/lib/message_service/persistence/query_plan.ex`
- `apps/backend/apps/message_service/lib/message_service/persistence/message_timeline_writes.ex`
- `apps/backend/apps/message_service/lib/message_service/persistence/message_timeline_reads.ex`
- `apps/backend/apps/message_service/lib/message_service/persistence/message_receipts.ex`
- `apps/backend/apps/message_service/lib/message_service/persistence/message_reactions.ex`
- `apps/backend/apps/message_service/lib/message_service/persistence/user_inbox_projection.ex`
- `apps/backend/apps/message_service/lib/message_service/projections/conversation_summary.ex`
- `apps/backend/apps/message_service/lib/message_service/events/message_created_log_consumer.ex`
- `apps/backend/apps/message_service/lib/message_service/events/conversation_summary_consumer.ex`
- `apps/backend/apps/message_service/lib/message_service/schemas/processed_event.ex`
- `apps/backend/apps/message_service/lib/message_service/schemas/conversation_message_summary.ex`
- `apps/backend/apps/message_service/test/message_service/conversation_summary_projection_test.exs`
- `apps/backend/apps/message_service/test/message_service/conversation_summary_consumer_integration_test.exs`
- `apps/backend/apps/message_service/test/message_service/boundaries_test.exs`
- `apps/backend/apps/message_service/test/message_service/persistence_query_plans_test.exs`

Current contract:

- `docs/05-api-contracts/message-service.md`

Current behavior:

- Message boundary functions return contract-aligned placeholder responses for API Gateway skeleton endpoints.
- Message persistence query-plan boundaries exist for message timeline writes/reads, receipts, reactions, and user inbox projection.
- `MessageStore` exposes `get_message/1`; `Messages.update_message`/`delete_message` enforce author-only edit/delete at this shared boundary (HTTP `403 message.forbidden`, channel `realtime.forbidden`).
- `MessageStore.PostgresAdapter` (+ `MessageService.Repo`, `Schemas.Message`/`Schemas.MessageReceipt`, tables in `infra/docker/postgres/init/020_message_store.sql`) provides real durability behind `MESSAGE_STORE_ADAPTER=postgres`. Default adapter remains `QueryPlanAdapter` (Docker-free). Live ScyllaDB execution is deferred (Phase 8; ecto/decimal conflict).
- After a successful create, `Messages.publish_message_created/1` emits `message.created.v1` fire-and-forget (flag `KAFKA_PUBLISH_ENABLED`, default off, wrapped in `Task.start`) to `message.events.v1` via `SharedInfra.Kafka.Producer` (default `NoopProducer`); publish failure never fails the create.
- `MessageService.Events.MessageCreatedLogConsumer` (`brod_group_subscriber_v2`) is the minimal consumer — flag-gated by `KAFKA_CONSUMER_ENABLED`, supervised in `MessageService.Application`, log/ack only (no projection/fanout). at-least-once → a future stateful consumer must dedupe on envelope `event_id`.
- `MessageService.Events.ConversationSummaryConsumer` (`brod_group_subscriber_v2`, flag `KAFKA_PROJECTION_CONSUMER_ENABLED`, distinct group `message-service-conversation-summary`, default off) is the **first stateful, idempotent consumer**. It calls `MessageService.Projections.ConversationSummary.apply_message_created/1`, which in ONE `Repo.transaction` inserts into the `processed_events` ledger (keyed `(consumer, event_id)`, `ON CONFLICT DO NOTHING`) and, only when new, upserts `conversation_message_summaries` (atomic `message_count` increment). Commit only after the DB tx; transient error → redeliver; malformed/poison event → skip+commit (UUID-validated via `fetch_uuid/2`). Schemas: `Schemas.ProcessedEvent`, `Schemas.ConversationMessageSummary`; tables in `infra/docker/postgres/init/030_message_projections.sql`. This is the dedupe blueprint for notification-service. Tests: `conversation_summary_projection_test.exs` (exactly-once, postgres_integration), `conversation_summary_consumer_integration_test.exs` (live round-trip, kafka_integration).
- Beyond author-only edit/delete + create/list membership (enforced in the gateway), no broader authorization checks (tenant/block — `Permissions.authorize/1` is still a placeholder), Redis integration, or Kafka publishing exists yet.

### notification_service

The FIRST of the 5 documented-only services to be built (`apps/backend/apps/notification_service`). Consumes `message.created.v1` → one notification record.

Key files:

- `apps/backend/apps/notification_service/mix.exs` (app `:notification_service`; deps shared_infra/ecto_sql/postgrex/brod/jason; mirrors message_service)
- `apps/backend/apps/notification_service/lib/notification_service/application.ex`
- `apps/backend/apps/notification_service/lib/notification_service/repo.ex`
- `apps/backend/apps/notification_service/lib/notification_service/notifications.ex`
- `apps/backend/apps/notification_service/lib/notification_service/events/message_created_consumer.ex`
- `apps/backend/apps/notification_service/lib/notification_service/events/conversation_participants_consumer.ex`
- `apps/backend/apps/notification_service/lib/notification_service/participant_read_model.ex`
- `apps/backend/apps/notification_service/lib/notification_service/schemas/processed_event.ex` (maps `notification_processed_events`)
- `apps/backend/apps/notification_service/lib/notification_service/schemas/notification.ex`
- `apps/backend/apps/notification_service/lib/notification_service/schemas/conversation_participant_readmodel.ex`
- `apps/backend/apps/notification_service/test/notification_service/notifications_test.exs` (exactly-once, postgres_integration)
- `apps/backend/apps/notification_service/test/notification_service/participant_read_model_test.exs` (convergence/LWW, postgres_integration)
- `apps/backend/apps/notification_service/test/notification_service/participant_read_model_invalid_test.exs` (plain invalid-event)
- `apps/backend/apps/notification_service/test/notification_service/message_created_consumer_integration_test.exs` (live wiring, kafka_integration)
- `apps/backend/apps/notification_service/test/support/data_case.ex`

Current behavior:

- `NotificationService.Events.MessageCreatedConsumer` (`brod_group_subscriber_v2`, flag `NOTIFICATION_CONSUMER_ENABLED`, distinct group `notification-service-message-created`, default off) calls `NotificationService.Notifications.apply_message_created/1`, which in ONE `Repo.transaction` inserts into the `notification_processed_events` ledger (`(consumer="notification", event_id)`, coarse gate) and, when new, **FANS OUT**: reads the active recipient set from `conversation_participants_readmodel` (`WHERE conversation_id=? AND active`, EXCLUDING `sender_user_id`) and `insert_all`s ONE `notifications` row per recipient (`recipient_user_id`) with `on_conflict: :nothing` on the UNIQUE `(source_event_id, recipient_user_id)` index — the durable per-recipient idempotency guard. Empty read-model (cold-start) → 0 rows, no crash. Tables in `040_notifications.sql` + `042_notifications_fanout.sql`.
- `NotificationService.Events.ConversationParticipantsConsumer` (`brod_group_subscriber_v2`, flag `NOTIFICATION_PARTICIPANTS_CONSUMER_ENABLED`, distinct group `notification-service-conversation-participants`, topic `conversation.events.v1`, default off) maintains the LOCAL participant read-model via `NotificationService.ParticipantReadModel`. `apply_participant_added/1`/`apply_participant_removed/1`: ONE `Repo.transaction` doing dedupe insert into `notification_processed_events` (DISTINCT consumer `notification-participants`) then, when new, an upsert into `conversation_participants_readmodel`. Soft state (`active` boolean, never hard-deleted) + occurred_at **last-writer-wins** (`ON CONFLICT ... WHERE EXCLUDED.last_event_at >= table.last_event_at`) → idempotent on redelivery AND convergent under out-of-order delivery. Table in `infra/docker/postgres/init/041_notification_participants_readmodel.sql`. Consumer dispatches on `event_type` (added/removed → apply; other → skip+commit). This read-model is what (c) fan-out will read to resolve recipients.
- `NotificationService.Application.children/0` is `[]` when BOTH consumer flags are off (Docker-free, nothing connects); when EITHER is on it starts `[Repo, brod client]` + each enabled consumer (the brod client is shared across both group subscribers). The Repo-only tests start their Repo via `NotificationService.DataCase`, decoupled from the flags.
- (c) recipient fan-out DONE (one notification per active participant, sender excluded). Still NOT built: push/email/SMS delivery, `notification_preferences`/`push_tokens`, `notification.sent.v1` publishing.
- Test infra: all DataCases start the Repo UNLINKED (`Process.unlink/1`) so a failing test cannot kill the shared Repo and cascade `Sandbox.checkout` "no process" failures across the pg suite.

### media_service

Media upload and access service shell.

Important files:

- `apps/backend/apps/media_service/lib/media_service/application.ex`
- `apps/backend/apps/media_service/lib/media_service/media.ex`
- `apps/backend/apps/media_service/lib/media_service/storage.ex`
- `apps/backend/apps/media_service/test/media_service/media_test.exs`
- `apps/backend/apps/api_gateway/lib/api_gateway_web/controllers/media_controller.ex`
- `apps/backend/apps/api_gateway/test/api_gateway_web/controllers/media_controller_test.exs`

Current contract:

- `docs/05-api-contracts/media-service.md`

Current behavior:

- Media upload, completion, and download URL boundaries exist.
- Media Service validates required fields, safe content types, object key generation, and adapter results.
- API Gateway exposes `/api/v1/media/uploads`, `/api/v1/media/uploads/:media_id/complete`, and `/api/v1/media/:media_id/download`.
- The safe in-memory adapter supports Docker-free tests; live MinIO/S3 signing remains deferred because no storage client dependency is installed.

### realtime_gateway

Phoenix Channels and future Presence boundary.

Important files:

- `apps/backend/apps/realtime_gateway/lib/realtime_gateway/application.ex`
- `apps/backend/apps/realtime_gateway/lib/realtime_gateway/infrastructure.ex`
- `apps/backend/apps/realtime_gateway/lib/realtime_gateway/user_socket.ex`
- `apps/backend/apps/realtime_gateway/lib/realtime_gateway/topic_authorization.ex`
- `apps/backend/apps/realtime_gateway/lib/realtime_gateway/conversation_channel.ex`
- `apps/backend/apps/realtime_gateway/lib/realtime_gateway/user_channel.ex`
- `apps/backend/apps/realtime_gateway/lib/realtime_gateway/call_channel.ex`
- `apps/backend/apps/realtime_gateway/test/realtime_gateway/channels_test.exs`

Current contract:

- `docs/05-api-contracts/realtime-gateway.md`

Current behavior:

- API Gateway mounts the Phoenix socket at `/socket`.
- Realtime Gateway supports skeleton joins for `conversation:{conversation_id}`, `user:{user_id}`, and `call:{call_id}`.
- Realtime Gateway can opt into socket auth via Auth Service session lookup and DB-aware conversation join authorization via Conversation Service membership checks. Socket auth fails closed: with `REALTIME_AUTH_DB_BACKED` on but `AUTH_SESSION_DB_BACKED` off (session layer not DB-backed), connections are rejected (`require_db_backed_sessions`) rather than accepting the placeholder identity.
- Conversation channel supports `message:create`/`message:new`, `message:update`, and `message:delete` event boundaries that call Message Service and broadcast `message_created`/`message_updated`/`message_deleted` (via `broadcast_from`) on success.
- Client event handlers return placeholder acknowledgements for typing, read/delivered receipts, and call signaling.
- No production JWT authentication, Redis Presence, Kafka consumption, or Kafka publishing exists yet.

### shared_infra

Shared Redis, Kafka, and ScyllaDB client boundaries for backend services.

Important files:

- `apps/backend/apps/shared_infra/lib/shared_infra/redis/client.ex`
- `apps/backend/apps/shared_infra/lib/shared_infra/prod_config.ex` (prod fail-fast secret guard; called from `config/runtime.exs`; unit-tested in `prod_config_test.exs`)
- `apps/backend/apps/shared_infra/lib/shared_infra/auth_client.ex` (Auth service-client boundary: behaviour + dispatcher; adapter from `:shared_infra, :auth_client_adapter`; the microservices-split seam — edge apps call this instead of `AuthService.*`)
- `apps/backend/apps/auth_service/lib/auth_service/auth_client_in_process.ex` (default in-process adapter delegating to `AuthService.Sessions/OTP/Tokens`)
- `apps/backend/apps/shared_infra/lib/shared_infra/http_client.ex` (`SharedInfra.HttpClient` — shared `:httpc` helper for all HTTP client adapters: build req + `x-internal-token` + JSON + timeouts; 200→`decode_result`, transport failure→`{:error, unavailable_atom}`. Req intended but offline-unavailable → `:httpc`, isolated here for later swap)
- `apps/backend/apps/shared_infra/lib/shared_infra/auth_client_http.ex` (`SharedInfra.AuthClientHttp` — HTTP adapter for `SharedInfra.AuthClient`, lives in shared_infra not auth_service; flip via `AUTH_CLIENT_ADAPTER=http`+`AUTH_SERVICE_URL`; transport failure→`:auth_unavailable`, gateway→503)
- `apps/backend/apps/shared_infra/lib/shared_infra/conversation_client_http.ex` (`SharedInfra.ConversationClientHttp` — HTTP adapter for `SharedInfra.ConversationClient`; flip via `CONVERSATION_CLIENT_ADAPTER=http`+`CONVERSATION_SERVICE_URL`; transport failure→`:conversation_unavailable`→503/realtime.unavailable at every gateway+realtime call-site)
- `apps/backend/apps/shared_infra/lib/shared_infra/user_client_http.ex` (`SharedInfra.UserClientHttp` — HTTP adapter for `SharedInfra.UserClient`; flip via `USER_CLIENT_ADAPTER=http`+`USER_SERVICE_URL`; transport failure→`:user_unavailable`→503 at every user_controller site)
- `apps/backend/apps/shared_infra/lib/shared_infra/conversation_client.ex` (Conversation service-client boundary; adapter from `:shared_infra, :conversation_client_adapter`; edge apps call this instead of `ConversationService.*`)
- `apps/backend/apps/conversation_service/lib/conversation_service/conversation_client_in_process.ex` (default in-process adapter delegating to `ConversationService.{Conversations,Participants}`)
- `apps/backend/apps/shared_infra/lib/shared_infra/user_client.ex` (User service-client boundary; adapter from `:shared_infra, :user_client_adapter`; edge apps call this instead of `UserService.*`)
- `apps/backend/apps/user_service/lib/user_service/user_client_in_process.ex` (default in-process adapter delegating to `UserService.Profiles`)
- `apps/backend/apps/shared_infra/lib/shared_infra/message_client.ex` (Message service-client boundary; adapter from `:shared_infra, :message_client_adapter`; both edges call this instead of `MessageService.*`; `list_timeline` → `Timeline.list_messages`)
- `apps/backend/apps/message_service/lib/message_service/message_client_in_process.ex` (default in-process adapter delegating to `MessageService.{Messages,Timeline,Receipts}`)
- `apps/backend/apps/shared_infra/lib/shared_infra/media_client.ex` (Media service-client boundary; adapter from `:shared_infra, :media_client_adapter`; edge apps call this instead of `MediaService.Media.*`)
- `apps/backend/apps/media_service/lib/media_service/media_client_in_process.ex` (default in-process adapter delegating to `MediaService.Media`)
- **Client-boundary set COMPLETE:** all 5 edge→service seams (Auth/Conversation/User/Message/Media) route through `SharedInfra.*Client` dispatchers (in-process default adapters); no edge app (api_gateway, realtime_gateway) calls any `*Service.*` domain module directly.
- `apps/backend/apps/shared_infra/lib/shared_infra/internal_api.ex` — `SharedInfra.InternalApi` (internal service↔service result-envelope: encode_result/decode_result, atom-key rehydration, preserves error atoms) + `SharedInfra.InternalApi.TokenPlug` (internal `x-internal-token` auth, fails closed). Shared base for all services' internal HTTP APIs. Contract: `docs/09-devops/INTERNAL_API.md`.
- `apps/backend/apps/auth_service/lib/auth_service/http/router.ex` — `AuthService.HTTP.Router` (Plug, not Phoenix): the internal HTTP API for auth (routes 1:1 with `SharedInfra.AuthClient`). Listener is a `Plug.Cowboy` child in `AuthService.Application`, gated `AUTH_HTTP_API_ENABLED` (default off → no listener at boot). The Auth TEMPLATE; user/message/media copy it. NOT called yet (in-process adapters stay default).
- `apps/backend/apps/conversation_service/lib/conversation_service/http/router.ex` — `ConversationService.HTTP.Router` (same template; routes 1:1 with `SharedInfra.ConversationClient`; atom-keyed conversation/participant responses). Listener gated `CONVERSATION_HTTP_API_ENABLED` (default off).
- `apps/backend/apps/user_service/lib/user_service/http/router.ex` — `UserService.HTTP.Router` (same template; routes 1:1 with `SharedInfra.UserClient`; profile responses atom-keyed). Listener gated `USER_HTTP_API_ENABLED` (default off).
- `apps/backend/apps/message_service/lib/message_service/http/router.ex` — `MessageService.HTTP.Router` (same template; 9 routes 1:1 with `SharedInfra.MessageClient` incl. `list_timeline`→`Timeline.list_messages`; metadata is free-form/string-keyed — client adapter must not atomize it). Listener gated `MESSAGE_HTTP_API_ENABLED` (default off).
- `apps/backend/apps/media_service/lib/media_service/http/router.ex` — `MediaService.HTTP.Router` (same template; routes 1:1 with `SharedInfra.MediaClient`; the listener is media's ONLY child — no Repo). Listener gated `MEDIA_HTTP_API_ENABLED` (default off). **Internal-API set COMPLETE (all 5 services).**
- `apps/backend/apps/shared_infra/lib/shared_infra/kafka/producer.ex`
- `apps/backend/apps/shared_infra/lib/shared_infra/kafka/consumer.ex`
- `apps/backend/apps/shared_infra/lib/shared_infra/scylla/client.ex`
- `apps/backend/apps/shared_infra/lib/shared_infra/config/redis.ex`
- `apps/backend/apps/shared_infra/lib/shared_infra/config/kafka.ex`
- `apps/backend/apps/shared_infra/lib/shared_infra/config/scylla.ex`
- `apps/backend/apps/shared_infra/lib/shared_infra/test_adapters/redis.ex`
- `apps/backend/apps/shared_infra/lib/shared_infra/test_adapters/kafka_producer.ex`
- `apps/backend/apps/shared_infra/lib/shared_infra/test_adapters/kafka_consumer.ex`
- `apps/backend/apps/shared_infra/lib/shared_infra/test_adapters/scylla.ex`
- `apps/backend/apps/shared_infra/test/shared_infra/config_test.exs`
- `apps/backend/apps/shared_infra/test/shared_infra/test_adapters_test.exs`

Current behavior:

- Defines dependency-free behaviours for future Redis clients, Kafka producers, Kafka consumers, and ScyllaDB clients.
- `SharedInfra.Kafka.Producer` is a dispatcher (selects `:shared_infra, :kafka_producer_adapter`); default `NoopProducer`, or the real `SharedInfra.Kafka.BrodProducer` (jason-encode + async `:brod.produce` + `:hash`) via `KAFKA_PRODUCER_ADAPTER=brod`. The flag-gated brod client is supervised in `MessageService.Application` (started only when the brod adapter is selected). `SharedInfra.Events.Envelope` builds/validates the standard envelope. `message.created.v1` is produced fire-and-forget (consumer side pending).
- Provides safe config helpers over existing Redis, Kafka, and ScyllaDB placeholders.
- Provides dummy adapters for unit tests without live Redis, Kafka, or ScyllaDB connections.
- `SharedInfra.ProdConfig` is the prod fail-fast secret guard: `config/runtime.exs` (prod-only) calls `require_secret!/1`/`require_present!/1` to refuse boot on missing/placeholder `SECRET_KEY_BASE`/`TOKEN_SECRET`/`OTP_SECRET`/`DATABASE_URL`.
- **Repo supervision (deploy boot):** each Repo-owning app (auth/user/conversation/message/notification) supervises its Repo at boot via `Application.get_env(:<app>, :start_repo, true)` — default true (dev/prod), `false` in `config/test.exs` so `:test` does not start Repos at boot (DataCase does, per-test) → plain `mix test` stays Docker-free.
- No production connection pools wired beyond the runtime.exs Repo config (deploy-only verification), no live Kafka in prod (flag-gated, staged off), Redis Presence/Scylla still pending.
