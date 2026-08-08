# AI Context

## Project Name

chat-platform

## Product Goal

Build an enterprise-grade chatting platform that supports B2B, B2C, and C2C communication.

The platform should support WhatsApp-like features including chat, group chat, audio calls, video calls, media sharing, presence, typing indicators, delivery status, read receipts, notifications, and admin controls.

## Current Phase

**Deployed and serving traffic.** [VERIFIED 2026-08-05] Production runs the multi-container split
(gateway + auth/conversation/user/message/media/notification over `chatnet`), Postgres-backed, with
1876 messages in `messages`. Android and web clients are live against it.

- ~~Phase 0: Documentation and architecture planning.~~ **← FALSE.** Left visible rather than deleted:
  an AI session priming on "documentation and architecture planning" would assume nothing is built and
  propose greenfield work against a running system. This is the highest-consequence line in the file.

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
- **ScyllaDB is the source of truth for message timelines — since 2026-08-08.** [VERIFIED at the
  cutover] `MESSAGE_STORE_ADAPTER=scylla`, sourced from the host `.env` (the compose file requires
  it via `${VAR:?}`). The Postgres `messages` table is FROZEN: reading it reads a pre-cutover
  snapshot (that mistake, made by the inbox reconciler, silently reverted live previews on cutover
  day — DECISION_LOG 2026-08-08). Message *search* is served from the `message_search` copy in
  Postgres (a recorded decision, same date); the inbox row is maintained by the Kafka inbox
  projection.
  - History of this bullet, kept because it has flipped TWICE: the original said Scylla was the
    source of truth when it was only an intent (corrected 2026-08-05 to "PostgreSQL, never run in
    production" — verified true then); the cutover made that correction false in turn. A present-
    tense store claim in a priming doc rots at every flip — hence the pointer rule below.
  - **The ladder's live state and the rollback procedure live in
    [docs/09-devops/SCYLLA_FLIP_RUNBOOK.md](../09-devops/SCYLLA_FLIP_RUNBOOK.md), and are deliberately
    NOT restated here.** Two copies of that state is what produced this contradiction in the first
    place — one of them was always going to rot. Follow the link; do not summarise it back into this
    file.
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

- **Cross-day edit/delete partition miss — Scylla-specific, N/A to the Postgres store.** The issue exists only for the Scylla/InMemory adapters that locate rows by `(conversation_id, bucket_date, message_id)`. The new `MessageStore.PostgresAdapter` (the durability backend, `MESSAGE_STORE_ADAPTER=postgres`) looks up by `message_id` / `conversation_id` only — no partitions — so cross-day edit/delete works correctly there. **[CORRECTED 2026-08-05]** ~~If/when the live Scylla backend lands (Phase 8), the fix (derive `bucket_date` from the timeuuid `message_id`) is needed for that adapter.~~ That fix has LANDED: `ScyllaAdapter.get_message/1` is a bucket-derived point read (bucket from the timeuuid via `ScyllaCodec`), verified against a live engine in CI. The adapter is built and CI-tested; it has never run in production.
- **Message durability — IMPLEMENTED on Postgres (2026-06-18).** `MessageStore.PostgresAdapter` + `MessageService.Repo` + `messages`/`message_receipts` tables; gated by `MESSAGE_STORE_ADAPTER=postgres`; default adapters unchanged (Docker-free plain `mix test`). **[CORRECTED 2026-08-05]** ~~ScyllaDB high-write backend deferred to Phase 8 (ecto/decimal conflict).~~ The ecto/decimal conflict is RESOLVED — `{:decimal, "~> 3.0", override: true}` in the root `mix.exs` (with the precise safety boundary documented there), and `{:xandra, "~> 0.19"}` is a resolved dependency. Postgres remains the production store; see the message-store rule above and SCYLLA_FLIP_RUNBOOK.md for the ladder.
- **HTTP message create/list membership — ENFORCED (2026-06-18).** `message_controller.ex` `authorize_membership/2` now calls `ConversationService.Conversations.get_conversation/1` (same check as WS channel-join) before create/list; non-participants get `403 message.forbidden`. Active when `CONVERSATION_DB_BACKED` on; flag-off placeholder path unchanged. Still open: block-state/tenant authz for messaging and the `Permissions.authorize/1` placeholder; participant add/remove already had owner checks.
- **Author-only edit/delete — ENFORCED (2026-06-18).** `MessageService.Messages.update_message`/`delete_message` now fetch the stored message via `MessageStore.get_message/1` and reject a non-author with `{:error, :message_forbidden}` (`messages.ex` `authorize_author/4`). One check at the shared boundary covers both HTTP (`403 message.forbidden`) and channel (`realtime.forbidden`). Still open: broader edit/delete authz (participant/tenant/block) — `MessageService.Permissions.authorize/1` is still a placeholder returning `true`; and admin-override delete is not modeled.
- **Channel socket-auth — GUARDED, partial-on now fails closed (2026-06-18).** Trustworthy socket identity requires BOTH `REALTIME_AUTH_DB_BACKED` AND `AUTH_SESSION_DB_BACKED` on; the socket validates tokens via the same `AuthService.Sessions.current_session/1` as HTTP. `RealtimeGateway.UserSocket.require_db_backed_sessions` now rejects the connection if socket auth is on but the session layer isn't genuinely DB-backed (no more silent shared placeholder identity). Still open (own slices, NOT done): flipping flag defaults to ON (would break Docker-free dev/tests) is a deployment/config decision; and true JWT signing + key rotation (tokens are a custom HMAC signed-envelope, not RS256/JWKS). With socket auth OFF (local-dev default) the placeholder path still trusts a client-provided `user_id` by design.
- **Test counts are per-app.** Root `mix test` prints a separate `Result:` line per umbrella app (api_gateway last). CI exit code aggregates all apps. **[CORRECTED 2026-08-05]** ~~True aggregates: `mix test` → 169 passed / 48 excluded; `--include postgres_integration` → 216 passed.~~ Those numbers are long stale and are deliberately NOT replaced with today's: a hardcoded count in a priming document re-rots every slice. Get the current numbers by RUNNING the gates — `./scripts/test-postgres.sh` and `./scripts/test-scylla.sh` both print their suite count AND their excluded-suite count, which is the number that actually matters.

- **Kafka — dormant scaffolding only (2026-06-18). [STALE HEADLINE — LIVE SINCE 2026-07/08: producer + six consumer groups run in production; the paragraph below is the 2026-06-18 snapshot of how the scaffolding began.]** `SharedInfra.Kafka.Producer` is a dispatcher with a non-connecting `NoopProducer` default (`:shared_infra, :kafka_producer_adapter`); `SharedInfra.Events.Envelope` builds/validates the standard event envelope. **brod `~> 4.0` is now installed and compiling** (cmake present; brod 4.5.5/kafka_protocol 4.3.4/crc32cer 1.1.3) but **present-and-unused** — dispatcher still defaults to `NoopProducer`, nothing produces/consumes, nothing connects (Docker-free; counts unchanged 183/56). **First event flow reaches a real broker (2026-06-18):** `message.created.v1` is published **fire-and-forget** (emit wrapped in `Task.start`) after a successful message persist (`MessageService.Messages.publish_message_created/1`), flag-gated by `KAFKA_PUBLISH_ENABLED` (default off), to topic `message.events.v1` (6 partitions). The `SharedInfra.Kafka.Producer` boundary defaults to `NoopProducer`; setting `KAFKA_PRODUCER_ADAPTER=brod` selects the real **brod-backed adapter** (`BrodProducer`: jason-encode + async `:brod.produce` + `:hash` on conversation_id), with a flag-gated brod client supervised in `MessageService.Application`. Publish failure/latency NEVER affects a create (async + Task.start + try/rescue). Verified live via `--include kafka_integration`. **Consumer side now exists:** a minimal log/ack consumer (`MessageCreatedLogConsumer`, `KAFKA_CONSUMER_ENABLED`) and the **first stateful, idempotent consumer** (`ConversationSummaryConsumer`, `KAFKA_PROJECTION_CONSUMER_ENABLED`, distinct group) maintaining the `conversation_message_summaries` projection deduped via the `processed_events` ledger (exactly-once on redelivery, poison-skip on malformed events) — the dedupe blueprint for notification-service. All flag-gated/default off. Backend build requires a C toolchain + cmake (for `crc32cer`'s NIF); CI (`backend-ci.yml` lines 31-32) installs it; local dev needs the same (`brew install cmake`).

## Current Next Step

**[SUPERSEDED 2026-08-05 — the 2026-06-18/23 build log that stood here has been REMOVED, not
corrected.]** It described notification-service being built, the microservices split, and a planned
Fly deployment as *in progress*. All three are **done**: notification_service is an umbrella app, the
split runs in production (`*_CLIENT_ADAPTER=http` over `chatnet`), and deployment is
`docker-compose.prod.yml` on a host — the Fly plan was superseded, not completed.

It was deleted rather than dated because this is a PRIMING file: ~15 lines of dense seven-week-old
narrative under a heading that says "Current" is worse than nothing, and the history is preserved in
full in [DECISION_LOG.md](../11-decisions/DECISION_LOG.md) and
[SESSION_LOG.md](./SESSION_LOG.md) — this was a third copy, not the record.

**For what is actually next:** [PROJECT_STATUS.md](./PROJECT_STATUS.md) (current-state banner) and,
for the Scylla ladder specifically, [SCYLLA_FLIP_RUNBOOK.md](../09-devops/SCYLLA_FLIP_RUNBOOK.md).

Other open work: message-list pagination; block-state/tenant authz + `Permissions.authorize/1` placeholder; **[CORRECTED 2026-08-05]** ~~ScyllaDB live backend (Phase 8)~~ → the Scylla adapters are BUILT and CI-tested; what remains is the operational ladder, per SCYLLA_FLIP_RUNBOOK.md. **[CORRECTED 2026-08-05]** ~~the 4 remaining missing services (tenant/call-signaling/moderation/audit)~~ → those four lack an umbrella APP DIRECTORY, but every one of the capabilities is implemented (tenancy = `apps` table + `app_id`; call-signaling = `realtime_gateway/call_signaling.ex`; moderation = `auth_service/moderation.ex`; audit = `AuthClient.write_audit/1`). The open question is whether to EXTRACT them as services — see PROJECT_STATUS.md. CI installs cmake for the brod NIF.
