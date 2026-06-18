# Project Status — Code-Verified Completion Audit

**Date:** 2026-06-18 · **Type:** read-only audit (no source changed; this file is the only write)
**Method:** every claim verified against source (file:line) or a run command. Trust code, not docs.

---

## 1. Executive summary

The repo is a **clean, well-tested foundation for the chat MVP, running entirely on flag-gated / in-memory infrastructure.** The HTTP + WebSocket surface is fully wired, the web client exercises the whole chat loop, and the auth slice is genuinely DB-backed and tested. But the "enterprise, event-driven microservices platform" the docs describe is mostly **not built**: Kafka is 0% wired, no live ScyllaDB driver exists, 5 of 12 documented services have no code, and 16 of 28 Postgres tables have no Ecto schema.

- **Overall vs. full documented vision: ~38%.**
- **Chat-MVP completion (does the core loop work end-to-end?): ~80%** — works in the flag-on + local-infra config; gaps are membership authz on HTTP message create/list, no live message-store verification, and no automated web tests.
- **Production-grade completion: ~40%** — insecure default secrets, flags default OFF (unenforced), no live message persistence, no events, no observability, no deploy pipeline.

Roadmap position: Phases 0/1/3 done, **Phase 4 (Chat MVP) ~85%**, Phase 5 (Media) ~40%, Phases 2/6/7 ~0–10%.

---

## 2. Per-service status

| Service | Purpose | Status | Tests | Key gaps |
|---|---|---|---|---|
| **api_gateway** | REST + WS entry | ✅ wired | controller tests pass (39/35) | rate-limit plug only on `/otp/request`, OFF by default |
| **auth_service** | OTP, tokens, sessions, devices | ✅ real + tested | boundary + pg-integration (24/1) | insecure default secrets; `devices.ex` `:not_implemented`; login-attempt throttle recorded not enforced; custom HMAC envelope (not JWT) |
| **user_service** | profile/settings/privacy | 🟡 flag-gated (`USER_PROFILE_DB_BACKED`) | boundary + schema + pg (12/3) | settings/privacy placeholder-only; no user search |
| **conversation_service** | conversations/participants/groups | 🟡 flag-gated (`CONVERSATION_DB_BACKED`) | boundary + schema + pg (14/8) | real participant/owner authz only flag-on; `Permissions.authorize/1` placeholder; groups placeholder |
| **message_service** | messages/receipts/reactions/timeline | 🟡 flag-gated (`MESSAGE_DB_BACKED`) + ⚠️ no live store | boundary tests via InMemory + TestScyllaClient (34) | **no live Scylla driver**; author-only edit/delete enforced, but **no membership check on create/list**; reactions placeholder |
| **media_service** | upload/download URLs | 🟡 flag-gated (`MEDIA_DB_BACKED`) | media_test (9) | real MinIO SigV4 signer; default adapter unavailable; no upload verification; no DB metadata table schema |
| **realtime_gateway** | WS channels + presence | 🟡 flag-gated (`REALTIME_AUTH_DB_BACKED`) | channels_test (22) + 2 pg socket-auth | presence local-only (no Redis); socket auth fails-closed but OFF by default |
| **shared_infra** | kafka/redis/scylla boundaries + rate limiter | 🟡 | config + rate_limiter (20/1) | Kafka/Scylla are behaviours only; real Redis rate-limiter adapter exists |
| **notification_service** | consumes `message.created.v1` → notification record | 🟡 flag-gated (`NOTIFICATION_CONSUMER_ENABLED`) | notifications idempotency (2 pg) + 1 kafka wiring | FIRST of the 5 missing services now built; minimal consumer, no recipient fan-out yet |
| *tenant / call-signaling / moderation / audit* | documented services | 🔴 **no code** | — | no `apps/backend/apps/<name>` dir exists (notification-service now built; 4 of 5 remain) |

---

## 3. Feature coverage vs. PRODUCT_REQUIREMENTS

⚠️ **`docs/01-product/PRODUCT_REQUIREMENTS.md` is an empty stub (1 line).** There is no authoritative product spec; scope is inferred from ROADMAP + SERVICE_CATALOG + contracts. (Doc correction #1.)

Against the inferred Chat-MVP feature set:
| Feature | Status |
|---|---|
| Signup/login via OTP | ✅ real + tested (auth pg-integration) |
| Create/list conversations | 🟡 works flag-on; participant authz real (VIEW), tested |
| Send / list messages (text+media) | 🟡 works flag-on; **persistence only in-memory/query-plan, never live Scylla** |
| Edit / delete messages | ✅ author-only enforced + tested |
| Delivery / read receipts | 🟡 flag-gated; single-status CQL (delivered may be overwritten by read) |
| Typing indicator | ✅ (single-node broadcast) |
| Presence | 🟡 local `Phoenix.Presence` only; no Redis cluster-wide |
| Media image preview / Open media | ✅ web renders from `metadata.object_key` |
| Realtime live fan-out (create/edit/delete) | 🟡 implemented; **no automated web test — manual-check only (coverage gap)** |
| Notifications / calling / moderation / tenancy / audit | 🔴 not implemented |

---

## 4. API contract coverage

**All 22 documented REST endpoints are wired** in `api_gateway_web/router.ex` with matching controller actions (auth ×5, users ×3, conversations ×5, messages ×6, media ×3) + `GET /health`. **All documented WebSocket events** (`typing:start/stop`, `message_read/delivered`, `message:create/update/delete`) are implemented in `conversation_channel.ex`. One undocumented alias exists: `message:new` (→ same as `message:create`). No documented endpoint is missing from the router.

Caveat: "wired" ≠ "fully authorized/persisted" — see §5.

---

## 5. Data, events, security

### Postgres schema
28 tables created in `infra/docker/postgres/init/010_initial_schema.sql`; **only 12 have Ecto schemas** (auth ×5, user ×3, conversation ×4). **16 documented tables have no code** (tenant ×6, media ×3, call ×3, moderation ×4 — wait: tenant 6, media 3, call 3, moderation 4, audit 1 = 17 incl. audit). Media tables exist in SQL but media_service uses no DB schema. (Doc correction #2: SERVICE_CATALOG implies these are owned/used; in code they are unmodeled.)

### Message persistence — ✅ RESOLVED via Postgres (2026-06-18); ScyllaDB deferred
- **Real durability now runs on PostgreSQL** behind the swappable `MessageStore` adapter: `MESSAGE_STORE_ADAPTER=postgres` → `MessageService.MessageStore.PostgresAdapter` (new `MessageService.Repo` + `messages`/`message_receipts` tables in `infra/docker/postgres/init/020_message_store.sql`). Covered by pg-integration tests (create/list/edit/delete + media-metadata round-trip + non-author reject). Default adapters unchanged → plain `mix test` Docker-free.
- **ScyllaDB remains the documented long-term high-write backend, deferred** (Phase 8): blocked today by an ecto/decimal dependency conflict (Xandra needs `decimal ~> 2.0`, ecto pins `~> 3.0`). Default `SharedInfra.Scylla.Client` is still `UnavailableClient`; the `ScyllaAdapter` + query plans remain ready for when a driver lands. See DECISION_LOG 2026-06-18.

### Kafka — 🔴 0% wired
- `shared_infra/kafka/producer.ex` and `consumer.ex` are **behaviours only** (docstrings: "no Kafka consumption is wired… yet"). No live driver (`brod`/`kaffe`) in deps.
- **Zero produce/consume call sites** in any service. All 11 catalog topics + ~40 event types are documented but **never produced or consumed**. (Doc correction #3: KAFKA_EVENT_CATALOG describes producers per event that don't exist.)

### Authorization — what's REAL vs. stubbed (code-verified)
| Action | Real check? | Flag | Flag-off | Cite |
|---|---|---|---|---|
| Conversation VIEW | ✅ participant-active | `CONVERSATION_DB_BACKED` | placeholder | `conversations.ex` `get_conversation_from_db` |
| Participant ADD/REMOVE | ✅ owner role + can't-remove-owner | `CONVERSATION_DB_BACKED` | placeholder | `participants.ex:41-88` |
| Message EDIT/DELETE | ✅ author-only (`authorize_author/4` via `MessageStore.get_message`) → `403 message.forbidden` / `realtime.forbidden` | `MESSAGE_DB_BACKED` | placeholder | `messages.ex:121-184` |
| **Message CREATE** | ✅ membership-gated (2026-06-18) — `authorize_membership/2` → `get_conversation` participant check; non-member → `403 message.forbidden` | `CONVERSATION_DB_BACKED` (+ `MESSAGE_DB_BACKED`) | placeholder `{:ok}` (no enforcement) | `message_controller.ex` `create_message_from_store` + `authorize_membership/2` |
| **Message LIST** | ✅ membership-gated (2026-06-18) — same `authorize_membership/2` check | `CONVERSATION_DB_BACKED` (+ `MESSAGE_DB_BACKED`) | placeholder `{:ok}` | `message_controller.ex` `list_messages_from_store` |
| `*.Permissions.authorize/1` | 🔴 placeholder `authorized: true`, **never called** | — | — | `message_service/permissions.ex:14-20`, `conversation_service/permissions.ex:14-20` |

Nuance: over the **realtime channel**, creating a message requires first *joining* `conversation:{id}`, which `TopicAuthorization` gates on membership when `CONVERSATION_DB_BACKED` is on — so the WS create path is membership-gated, but the **HTTP** create/list paths are not.

### Socket auth (two-flag posture + fail-closed)
- Trustworthy identity requires **both** `REALTIME_AUTH_DB_BACKED` **and** `AUTH_SESSION_DB_BACKED` on; then the socket validates tokens via the same `AuthService.Sessions.current_session/1` as HTTP (signature + expiry + claims + device session + active user).
- **Fail-closed guard** (`user_socket.ex` `require_db_backed_sessions`): auth-on but session-layer-off → connection rejected (no silent placeholder identity). Tested (1 Docker-free + 2 pg-integration).
- OFF (local-dev default): trusts a client-provided `user_id` param — unauthenticated by design.

### Insecure default secrets (deploy-config risk code can't enforce)
- `auth_service/otp.ex` OTP secret falls back to literal `"local-otp-secret-change-before-production"` when env unset.
- `auth_service/tokens.ex` token secret falls back to `"local-token-secret-change-before-production"` (after `TOKEN_SECRET`/`SECRET_KEY_BASE`).
- All persistence/auth flags **default OFF**; nothing in code forces prod to enable them.

---

## 6. Verification results (Gate 0, exact)

| Command | Result |
|---|---|
| `mix test` (sum of all 8 apps) | **174 passed, 50 excluded**, 0 failures |
| `mix test --include postgres_integration` (sum) | **223 passed**, 0 failures |
| `npm run lint` / `typecheck` / `build` (web) | all green |

Note: prior runs cited "48 excluded"; true current is **50** (the socket-auth slice added 2 `postgres_integration` realtime tests, counted as excluded in the plain run). Per-app: media 9 · conversation 14/8 · shared_infra 20/1 · message 34 · auth 24/1 · realtime 22/2 · user 12/3 · api_gateway 39/35.

---

## 7. The two completion numbers (explicit)

### MVP completion: **~80%**
The core chat loop works end-to-end in the flag-on + local-infra configuration: OTP login → create/list conversations → send/list/edit/delete text+media messages → realtime fan-out → typing → media preview. Subtractions: (a) message persistence proven only in-memory, not against live Scylla; (b) **HTTP message create/list lack membership authz**; (c) presence is single-node; (d) **no automated web tests** (the live-messaging fan-out is manual-check only); (e) receipts use single-status CQL.

### Production-grade completion: **~40%**
Real blockers to shipping: insecure default secrets + flags default-off (unenforced); no live ScyllaDB driver (message durability unproven); Kafka entirely unwired (so notifications, audit, search, analytics — the whole event-driven design — are absent); no observability (tracing/metrics; `correlation_id` is the literal `"corr_placeholder"`); no deployment manifests / CI deploy step (CI runs format+compile+`mix test` only, no integration/web/Scylla/Kafka); 5 of 12 services and 16 of 28 tables unimplemented; no automated web tests.

---

## 8. Top risks / tech debt (prioritized)

1. ~~**HTTP message create/list have no membership authorization (HIGH).**~~ **RESOLVED 2026-06-18** — `message_controller.ex` `authorize_membership/2` now gates HTTP create/list on conversation participation (`403 message.forbidden`), reusing the WS channel-join check; flag-gated on `CONVERSATION_DB_BACKED`, tested (2 pg-integration negative tests). Remaining: block-state/tenant authz for messaging still TODO.
2. **Insecure default secrets + flags default-OFF (HIGH).** Prod safety depends entirely on env/config the code never enforces; a misconfigured deploy is silently insecure (OTP/token signing + unauthenticated sockets/authz).
3. ~~**No live message persistence (HIGH).**~~ **RESOLVED 2026-06-18** — durability implemented on Postgres (`PostgresAdapter`, `MESSAGE_STORE_ADAPTER=postgres`), pg-integration tested. ScyllaDB (high-write backend) deferred to Phase 8 (ecto/decimal conflict). Remaining: messages still need the Repo started + flag set in prod (not auto-started, same as other services).
4. **Kafka 0% wired (HIGH for the stated architecture).** Notifications, audit, search, presence fanout, analytics all depend on it.
5. **No automated web tests (MEDIUM).** The entire web client + the live realtime loop rest on lint/typecheck/build only.
6. **4 services + most Postgres tables documented but unimplemented (MEDIUM).** UPDATE 2026-06-18: **notification-service is now built** (first of the 5) — a flag-gated idempotent `message.created.v1` consumer that writes one notification record per event (`notifications` + `notification_processed_events` tables); recipient fan-out/delivery deferred. Still unimplemented: tenant/call-signaling/moderation/audit; tenancy/calls/moderation tables have no schema.
7. **Receipts single-status CQL (LOW/MEDIUM).** read can overwrite delivered; needs delivered_at/read_at columns.
8. **Cross-day `bucket_date` partition miss for edit/delete (LOW, tracked).** Editing a prior-day message misses its partition; fix: derive bucket_date from the timeuuid.
9. **Empty PRODUCT_REQUIREMENTS.md (MEDIUM).** No authoritative spec.

---

## 9. What's left to ship (prioritized backlog)

**Must-have (MVP correctness/durability):**
- **M** — membership authz on HTTP message create/list (reuse conversation participant check).
- **M** — fail-closed secrets + a startup guard that refuses prod with default secrets / flags off.
- **L** — live ScyllaDB driver (or pivot message store to Postgres) so messages actually persist.
- **M** — wire Kafka producer + the MVP event set (message.created/delivered/read, realtime connect/disconnect) and one consumer.
- **S/M** — automated web tests (at least one e2e/integration for the realtime create→fan-out loop).

**Nice-to-have / later phases:**
- **M** — Redis-backed presence + message-send rate-limit enforcement; receipts delivered_at/read_at.
- **M** — real OTP delivery (SMS/email via Mailpit locally); user search.
- **L** — true JWT signing + key rotation; web token-refresh + httpOnly cookies.
- **L** — observability (structured logs, real correlation IDs, metrics, tracing) + deployment manifests + CI integration/deploy.
- **L** — the 5 missing services (tenant/notification/call-signaling/moderation/audit) and their tables; Phase 2 Nx monorepo + mobile/admin/portal.

---

## 10. Defensible overall completion: **~38%**

Derived from implemented-and-tested surface against the full documented vision (not the docs' checkboxes): infra + backend foundation + the auth slice are genuinely done; the chat MVP works flag-on but on in-memory persistence with authz gaps and no web tests; and the platform's defining pieces — live message store, Kafka events, 5 services, observability, deploy — are absent. Weighting the roadmap (0/1/3 done; 4 ~85%; 5 ~40%; 2/6/7 ~0–10%) and discounting for "documented but unexercised" yields ~38% overall (MVP ~80%, production-grade ~40%).

---

## 11. Doc corrections (docs that disagreed with code)

1. **PRODUCT_REQUIREMENTS.md is empty** — presented as the product spec; it's a 1-line stub.
2. **DATABASE_DESIGN / SERVICE_CATALOG imply 28 owned tables / 12 services are real** — in code, 16 tables have no Ecto schema and 5 services have no app directory. media tables documented as media-service-owned but media_service uses no DB schema.
3. **KAFKA_EVENT_CATALOG lists producers/consumers per event** — none exist in code; Kafka is behaviour-only, zero call sites.
4. **ROADMAP Phase 4 shows the foundation items checked but the user-facing feature lines (signup/login, create conversation, message list, receipts, typing, presence) unchecked**, while those features are in fact implemented (flag-gated) and partly tested — the roadmap understates Phase 4. Conversely it does not capture the authz/persistence caveats. (Roadmap checkboxes are an unreliable completion proxy in both directions.)
5. **Realtime contract** previously listed `message_updated`/`message_deleted` server events before they existed (corrected in a prior slice; now implemented).
6. **Prior SESSION_LOG "48 excluded" figure** is now **50** (socket-auth slice added 2 pg-integration tests).
