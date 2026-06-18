# AI Context

## Project Name

chat-platform

## Product Goal

Build an enterprise-grade chatting platform that supports B2B, B2C, and C2C communication.

The platform should support WhatsApp-like features including chat, group chat, audio calls, video calls, media sharing, presence, typing indicators, delivery status, read receipts, notifications, and admin controls.

## Current Phase

Phase 0: Documentation and architecture planning.

## Tech Stack

### Frontend

- Nx monorepo
- React Native / Expo for mobile app
- Next.js for web app, admin dashboard, and business portal
- TypeScript

### Backend

- Phoenix / Elixir
- Microservices architecture
- Phoenix Channels for realtime communication
- Phoenix Presence for online/offline state

### Databases and Infrastructure

- PostgreSQL for transactional data
- ScyllaDB for high-volume chat messages
- Redis for cache, presence, typing indicators, sessions, rate limits
- Kafka for event streaming
- Docker for local development
- Kubernetes later for production deployment

## Main Applications

### Frontend Apps

- mobile
- web
- admin
- business-portal

### Backend Services

- api-gateway
- auth-service
- user-service
- tenant-service
- conversation-service
- message-service
- realtime-gateway
- notification-service
- media-service
- call-signaling-service
- moderation-service
- audit-service

## Architecture Rules

- Frontend must never connect directly to databases.
- All external frontend requests must go through API Gateway.
- Realtime communication should use Phoenix Channels.
- PostgreSQL is the source of truth for users, tenants, conversations, roles, permissions, and billing.
- ScyllaDB is the source of truth for message timelines.
- Redis is not a source of truth. It is only for temporary fast state.
- Kafka events must be versioned.
- Every important architecture decision must be added to Decision Log.
- Every completed session must update Session Log.

## Web Media Rendering (last verified: 2026-06-18)

- Chat bubbles render an inline `<img>` preview for media messages when `metadata.content_type` starts with `image/` and `metadata.object_key` is present, reusing the existing `getMediaDownloadUrl` resolver (one resolution per image, shared with the "Open media" link). Non-image / missing-object_key / load-failure cases fall back to the "Open media" link. See `apps/web/src/app/chat/page.tsx`.
- Verified facts only; full end-to-end media preview requires `MESSAGE_DB_BACKED` so `object_key` persists and rides the realtime `message_created` broadcast.

## Web Message Actions (last verified: 2026-06-18)

- Chat bubbles expose inline Edit (text-only) and Delete controls for the current user's own messages. When the conversation socket is connected the web edits/deletes over the channel (`message:update`/`message:delete`); HTTP `editMessage`/`deleteMessage` in `apps/web/src/lib/api.ts` remain as a fallback.
- Realtime propagation: `ConversationChannel` handles `message:update`/`message:delete` and broadcasts `message_updated`/`message_deleted`; the web subscribes and patches local state by `message_id`, so other connected clients see edits/deletes live (verified `apps/backend/apps/realtime_gateway/lib/realtime_gateway/conversation_channel.ex`).
- Message **creation** now also routes over the channel: the web pushes `message:create` (text + media, with media metadata) when the socket is connected (HTTP fallback otherwise), so new messages fan out to other clients live via `message_created`. The sender inserts from the channel reply; `mergeMessage` dedupes by `message_id` (see `apps/web/src/app/chat/page.tsx` `sendCreate`).

## Known Issues (tracked, code-verified)

- **Cross-day edit/delete partition miss — Scylla-specific, N/A to the Postgres store.** The issue exists only for the Scylla/InMemory adapters that locate rows by `(conversation_id, bucket_date, message_id)`. The new `MessageStore.PostgresAdapter` (the durability backend, `MESSAGE_STORE_ADAPTER=postgres`) looks up by `message_id` / `conversation_id` only — no partitions — so cross-day edit/delete works correctly there. If/when the live Scylla backend lands (Phase 8), the fix (derive `bucket_date` from the timeuuid `message_id`) is needed for that adapter.
- **Message durability — IMPLEMENTED on Postgres (2026-06-18).** `MessageStore.PostgresAdapter` + `MessageService.Repo` + `messages`/`message_receipts` tables; gated by `MESSAGE_STORE_ADAPTER=postgres`; default adapters unchanged (Docker-free plain `mix test`). ScyllaDB high-write backend deferred to Phase 8 (ecto/decimal conflict).
- **HTTP message create/list membership — ENFORCED (2026-06-18).** `message_controller.ex` `authorize_membership/2` now calls `ConversationService.Conversations.get_conversation/1` (same check as WS channel-join) before create/list; non-participants get `403 message.forbidden`. Active when `CONVERSATION_DB_BACKED` on; flag-off placeholder path unchanged. Still open: block-state/tenant authz for messaging and the `Permissions.authorize/1` placeholder; participant add/remove already had owner checks.
- **Author-only edit/delete — ENFORCED (2026-06-18).** `MessageService.Messages.update_message`/`delete_message` now fetch the stored message via `MessageStore.get_message/1` and reject a non-author with `{:error, :message_forbidden}` (`messages.ex` `authorize_author/4`). One check at the shared boundary covers both HTTP (`403 message.forbidden`) and channel (`realtime.forbidden`). Still open: broader edit/delete authz (participant/tenant/block) — `MessageService.Permissions.authorize/1` is still a placeholder returning `true`; and admin-override delete is not modeled.
- **Channel socket-auth — GUARDED, partial-on now fails closed (2026-06-18).** Trustworthy socket identity requires BOTH `REALTIME_AUTH_DB_BACKED` AND `AUTH_SESSION_DB_BACKED` on; the socket validates tokens via the same `AuthService.Sessions.current_session/1` as HTTP. `RealtimeGateway.UserSocket.require_db_backed_sessions` now rejects the connection if socket auth is on but the session layer isn't genuinely DB-backed (no more silent shared placeholder identity). Still open (own slices, NOT done): flipping flag defaults to ON (would break Docker-free dev/tests) is a deployment/config decision; and true JWT signing + key rotation (tokens are a custom HMAC signed-envelope, not RS256/JWKS). With socket auth OFF (local-dev default) the placeholder path still trusts a client-provided `user_id` by design.
- **Test counts are per-app.** Root `mix test` prints a separate `Result:` line per umbrella app (api_gateway last). True aggregates: `mix test` → 169 passed / 48 excluded; `--include postgres_integration` → 216 passed. CI exit code aggregates all apps.

- **Kafka — dormant scaffolding only (2026-06-18).** `SharedInfra.Kafka.Producer` is a dispatcher with a non-connecting `NoopProducer` default (`:shared_infra, :kafka_producer_adapter`); `SharedInfra.Events.Envelope` builds/validates the standard event envelope. **brod `~> 4.0` is now installed and compiling** (cmake present; brod 4.5.5/kafka_protocol 4.3.4/crc32cer 1.1.3) but **present-and-unused** — dispatcher still defaults to `NoopProducer`, nothing produces/consumes, nothing connects (Docker-free; counts unchanged 183/56). **First event flow is wired (2026-06-18):** `message.created.v1` is published **fire-and-forget** after a successful message persist (`MessageService.Messages.publish_message_created/1`), flag-gated by `KAFKA_PUBLISH_ENABLED` (default off), to topic `message.events.v1` via the `SharedInfra.Kafka.Producer` boundary (default `NoopProducer` → no-op; publish failure NEVER fails a create). Still pending: a live brod-backed producer adapter + the consumer side + remaining events. Backend build requires a C toolchain + cmake (for `crc32cer`'s NIF); CI (`backend-ci.yml` lines 31-32) installs `cmake build-essential` before compile; local dev needs the same (`brew install cmake`).

## Current Next Step

Kafka first event `message.created.v1` is wired (fire-and-forget, flag-gated, default `NoopProducer`). Next Kafka steps: a live brod-backed producer adapter (brod compiles now) + the consumer side. Other open work: PG message store enablement in dev/prod (Repo not auto-started); message-list pagination; block-state/tenant authz + `Permissions.authorize/1` placeholder; ScyllaDB live backend (Phase 8). CI now installs cmake for the brod NIF.
