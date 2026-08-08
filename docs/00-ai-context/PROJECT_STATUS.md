# Project Status

> ## READ THIS FIRST — CURRENT STATE [VERIFIED 2026-08-05]
>
> **The system is DEPLOYED and serving traffic.** Production runs the multi-container split
> (gateway + auth/conversation/user/message/media/notification over `chatnet`), Postgres-backed,
> with Android and web clients live against it.
>
> **Message store: ScyllaDB, since 2026-08-08.** `MESSAGE_STORE_ADAPTER=scylla`, sourced from the
> host `.env` (the compose file requires it via `${VAR:?}`). Writes AND reads are Scylla; the
> Postgres `messages` table is FROZEN — anything reading it reads a pre-cutover snapshot, which is
> how the inbox reconciler silently reverted live previews on cutover day (now interlocked; see
> DECISION_LOG 2026-08-08 entries). The inbox is maintained by the Kafka inbox-projection consumer,
> search by the search-index consumer over the `message_search` copy — both live, both required.
> **The rollback procedure lives in [SCYLLA_FLIP_RUNBOOK.md](../09-devops/SCYLLA_FLIP_RUNBOOK.md)
> and is deliberately NOT restated here** — two copies of that state is what produced the
> contradiction this file existed in for seven weeks. (This banner previously said `postgres` with
> "never run in production" — true when verified on 2026-08-05, false from the cutover on.)
>
> ### Do not read numbers from this file. Run the command.
>
> | Question | Command that answers it |
> |---|---|
> | test counts + **excluded-suite count** | `./scripts/test-postgres.sh` · `./scripts/test-scylla.sh` · `mix test` |
> | migrations | `ls apps/backend/apps/shared_infra/priv/schema/*.sql \| wc -l` |
> | live tables | `docker compose -f docker-compose.prod.yml exec -T postgres psql -U chat_user -d chat_platform -c '\\dt'` |
> | umbrella apps | `ls apps/backend/apps/` |
> | routes | `grep -cE '^\\s+(get\|post\|put\|patch\|delete) ' apps/backend/apps/api_gateway/lib/api_gateway_web/router.ex` |
>
> The excluded-suite count is the one that matters: a suite that is silently excluded is a gate that
> cannot fail. See DECISION_LOG [2026-08-05] on the format gate that returned 0 while checking nothing.
>
> ### Service inventory [VERIFIED 2026-08-05]
>
> **8 of the 12 documented services have an umbrella app.** 4 do not: `tenant`, `call-signaling`,
> `moderation`, `audit`. **But "no app directory" is NOT "no code" — all four capabilities are
> implemented elsewhere**, and a reader who believes otherwise will rebuild working features:
>
> | Documented service | App dir | Where the capability actually lives |
> |---|---|---|
> | tenant | ✗ | multi-tenancy is the `apps` table + `app_id` on every core table (migration 048) |
> | call-signaling | ✗ | `realtime_gateway/call_signaling.ex` + `conversation_service/call_store.ex` |
> | moderation | ✗ | `auth_service/moderation.ex` + `api_gateway/.../admin_moderation_controller.ex` |
> | audit | ✗ | `AuthClient.write_audit/1` + `list_audit/1` |
>
> The open question for these four is **whether to extract them as services**, not whether to build
> them. That is an architecture decision, not a backlog item.

---

> ## EVERYTHING BELOW IS A SUPERSEDED SNAPSHOT — 2026-06-18
>
> It is kept as a record of what was true then, not corrected line by line, because a document that
> *looks* current but is seven weeks and ~63 commits behind is more dangerous than one that is
> plainly dated. **Do not prime a session on it.** Where a claim below is actively contradicted by
> today's system it carries an inline `[STALE 2026-08-05]` marker; the rest is left as history.
>
> Its completion percentages (§1, §7, §10) are **superseded, not re-computed**: a subjective
> percentage in a priming document is the worst class of frozen number — it rots *and* it invites
> argument about the wrong thing. Ship-readiness now lives in the roadmap and the runbook.

# Project Status — Code-Verified Completion Audit (SUPERSEDED SNAPSHOT, 2026-06-18)

**Date:** 2026-06-18 · **Type:** read-only audit (no source changed; this file is the only write)
**Method:** every claim verified against source (file:line) or a run command. Trust code, not docs.

---

## 1. Executive summary

**[STALE 2026-08-05 — this paragraph is wrong in the UNDER-STATING direction; a reader who believes it will rebuild working features. See the banner at the top of this file.]** The repo is a **clean, well-tested foundation for the chat MVP, running entirely on flag-gated / in-memory infrastructure.** The HTTP + WebSocket surface is fully wired, the web client exercises the whole chat loop, and the auth slice is genuinely DB-backed and tested. But the "enterprise, event-driven microservices platform" the docs describe is mostly **not built**: Kafka is 0% wired, no live ScyllaDB driver exists, 5 of 12 documented services have no code, and 16 of 28 Postgres tables have no Ecto schema. **[STALE 2026-08-05: every clause here is now false. Kafka has `{:brod, "~> 4.0"}` as a resolved dep with five producer/consumer modules. Xandra `~> 0.19` is a resolved dep and the Scylla adapters are CI-tested on every push. FOUR (not five) documented services lack an app directory, and all four capabilities exist in code — see the banner. Table/schema counts: run the commands in the banner.]**

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
| **message_service** *(row [STALE 2026-08-05]: the store is live on Postgres in production; Scylla adapters are built + CI-tested)* | messages/receipts/reactions/timeline | 🟡 flag-gated (`MESSAGE_DB_BACKED`) + ⚠️ no live store | boundary tests via InMemory + TestScyllaClient (34) | **no live Scylla driver**; author-only edit/delete enforced, but **no membership check on create/list**; reactions placeholder |
| **media_service** | upload/download URLs | 🟡 flag-gated (`MEDIA_DB_BACKED`) | media_test (9) | real MinIO SigV4 signer; default adapter unavailable; no upload verification; no DB metadata table schema |
| **realtime_gateway** | WS channels + presence | 🟡 flag-gated (`REALTIME_AUTH_DB_BACKED`) | channels_test (22) + 2 pg socket-auth | presence local-only (no Redis); socket auth fails-closed but OFF by default |
| **shared_infra** | kafka/redis/scylla boundaries + rate limiter | 🟡 | config + rate_limiter (20/1) | Kafka/Scylla are behaviours only; real Redis rate-limiter adapter exists |
| **notification_service** | `message.created.v1` → fan-out one notification per recipient; local participant read-model from `conversation.events.v1` | 🟡 flag-gated (`NOTIFICATION_CONSUMER_ENABLED`, `NOTIFICATION_PARTICIPANTS_CONSUMER_ENABLED`) | fan-out + read-model convergence (pg) + kafka wiring | FIRST of the 5 missing services; **recipient fan-out DONE** — full event-driven cross-service flow (conversation events → read-model → per-recipient notifications) complete |
| *tenant / call-signaling / moderation / audit* | documented services | **[STALE 2026-08-05]** ~~🔴 no code~~ → no app DIRECTORY; the capability exists in each case (see the banner's inventory table) | — | the live question is whether to EXTRACT them, not whether to build them |

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
- **[STALE 2026-08-05]** ~~ScyllaDB remains the documented long-term high-write backend, deferred (Phase 8): blocked today by an ecto/decimal dependency conflict.~~ The conflict is RESOLVED (`{:decimal, "~> 3.0", override: true}` in the root `mix.exs`); `{:xandra, "~> 0.19"}` is a resolved dep in `shared_infra`; the adapters are complete and CI-tested. Postgres remains the production store. **Ladder state: [SCYLLA_FLIP_RUNBOOK.md](../09-devops/SCYLLA_FLIP_RUNBOOK.md), not here.**

### Kafka — 🔴 0% wired  **[STALE 2026-08-05: `{:brod, "~> 4.0"}` is a resolved dep; producer + five consumer modules exist across message/conversation/notification services, all flag-gated. Read the flags, not this heading.]**
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

### Insecure default secrets — ✅ GUARDED in prod (2026-06-18)
- The dev fallbacks still exist for dev/test (`otp.ex` `"local-otp-secret-change-before-production"`,
  `tokens.ex` `"local-token-secret-change-before-production"`), BUT `config/runtime.exs` now **fails
  fast in `:prod`** via `SharedInfra.ProdConfig`: it refuses to boot if `SECRET_KEY_BASE`/`TOKEN_SECRET`/
  `OTP_SECRET` are missing or match a known insecure placeholder, and requires `DATABASE_URL`. So a
  misconfigured prod deploy no longer boots silently insecure (audit #4 mitigated). Guard logic is
  unit-tested (`SharedInfra.ProdConfigTest`).
- Flags still default OFF, but `docs/09-devops/DEPLOYMENT.md` enumerates the exact prod flag set; a real
  deploy turns DB-backed core chat ON.
- **"Never run as a server" gap fixed:** Repos are now supervised at boot in dev/prod (gated off in
  `:test` so plain `mix test` stays Docker-free) — previously `children = []` meant a booted server
  crashed on the first DB request. `config/runtime.exs` + `config/prod.exs` + a `mix release` config now
  exist so `MIX_ENV=prod` can build/boot. Actual deploy (containerize + host) is the next sub-slices.

---

## 6. Verification results (Gate 0, exact)  **[STALE 2026-08-05 — do NOT read these counts. They are deliberately not updated: a frozen count re-rots every slice. Run the commands in the banner; the excluded-suite count is the number that matters.]**

| Command | Result |
|---|---|
| `mix test` (sum of all 8 apps) | **174 passed, 50 excluded**, 0 failures |
| `mix test --include postgres_integration` (sum) | **223 passed**, 0 failures |
| `npm run lint` / `typecheck` / `build` (web) | all green |

Note: prior runs cited "48 excluded"; true current is **50** (the socket-auth slice added 2 `postgres_integration` realtime tests, counted as excluded in the plain run). Per-app: media 9 · conversation 14/8 · shared_infra 20/1 · message 34 · auth 24/1 · realtime 22/2 · user 12/3 · api_gateway 39/35.

---

## 7. The two completion numbers (explicit)

> **[STALE AS OF 2026-08-08 — the two sections below are a pre-cutover snapshot.]** "No live
> ScyllaDB driver" and "Kafka entirely unwired" were true when written and are now FALSE: production
> serves messages from Scylla, and six Kafka consumers run live (notification fan-out, conversation
> summary, inbox projection, search index among them). Kept as-written because the percentages and
> subtractions describe that era's audit; the READ THIS FIRST banner is the current state.

### MVP completion: **~80%**
The core chat loop works end-to-end in the flag-on + local-infra configuration: OTP login → create/list conversations → send/list/edit/delete text+media messages → realtime fan-out → typing → media preview. Subtractions: (a) message persistence proven only in-memory, not against live Scylla; (b) **HTTP message create/list lack membership authz**; (c) presence is single-node; (d) **no automated web tests** (the live-messaging fan-out is manual-check only); (e) receipts use single-status CQL.

### Production-grade completion: **~40%**
Real blockers to shipping: insecure default secrets + flags default-off (unenforced); no live ScyllaDB driver (message durability unproven); Kafka entirely unwired (so notifications, audit, search, analytics — the whole event-driven design — are absent); no observability (tracing/metrics; `correlation_id` is the literal `"corr_placeholder"`); no deployment manifests / CI deploy step (CI runs format+compile+`mix test` only, no integration/web/Scylla/Kafka); 5 of 12 services and 16 of 28 tables unimplemented; no automated web tests.

---

## 8. Top risks / tech debt (prioritized)

1. ~~**HTTP message create/list have no membership authorization (HIGH).**~~ **RESOLVED 2026-06-18** — `message_controller.ex` `authorize_membership/2` now gates HTTP create/list on conversation participation (`403 message.forbidden`), reusing the WS channel-join check; flag-gated on `CONVERSATION_DB_BACKED`, tested (2 pg-integration negative tests). Remaining: block-state/tenant authz for messaging still TODO.
2. **Insecure default secrets + flags default-OFF (HIGH).** Prod safety depends entirely on env/config the code never enforces; a misconfigured deploy is silently insecure (OTP/token signing + unauthenticated sockets/authz).
3. ~~**No live message persistence (HIGH).**~~ **RESOLVED 2026-06-18** — durability implemented on Postgres (`PostgresAdapter`, `MESSAGE_STORE_ADAPTER=postgres`), pg-integration tested. ScyllaDB (high-write backend) deferred to Phase 8 (ecto/decimal conflict). **[STALE 2026-08-05: conflict resolved; adapters built + CI-tested; see the banner and the runbook.]** Remaining: messages still need the Repo started + flag set in prod (not auto-started, same as other services).
4. ~~**Kafka 0% wired (HIGH for the stated architecture).**~~ **RESOLVED across 2026-07/08** — producer + six consumer groups live in production (message events, notification fan-out, participants read-model, conversation summary, inbox projection 2026-08-08, search index 2026-08-08). Audit/analytics fanout still absent.
5. **No automated web tests (MEDIUM).** The entire web client + the live realtime loop rest on lint/typecheck/build only.
6. **[STALE 2026-08-05 — see the banner: 4 services lack an APP DIR, but all four capabilities are implemented; this item as written would cause a rebuild.]** **4 services + most Postgres tables documented but unimplemented (MEDIUM).** UPDATE 2026-06-18: **notification-service is now built** (first of the 5) — a flag-gated idempotent `message.created.v1` consumer that writes one notification record per event (`notifications` + `notification_processed_events` tables); recipient fan-out/delivery deferred. Still unimplemented: tenant/call-signaling/moderation/audit; tenancy/calls/moderation tables have no schema.
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
2. **DATABASE_DESIGN / SERVICE_CATALOG imply 28 owned tables / 12 services are real** — in code, 16 tables have no Ecto schema and 5 services have no app directory. **[STALE 2026-08-05: 4 services lack an app dir, not 5, and all four capabilities exist. This line is the origin of the "5 of 12" figure that propagated into AI_CONTEXT and elsewhere — it is corrected at the source here.]** media tables documented as media-service-owned but media_service uses no DB schema.
3. **KAFKA_EVENT_CATALOG lists producers/consumers per event** — none exist in code; Kafka is behaviour-only, zero call sites.
4. **ROADMAP Phase 4 shows the foundation items checked but the user-facing feature lines (signup/login, create conversation, message list, receipts, typing, presence) unchecked**, while those features are in fact implemented (flag-gated) and partly tested — the roadmap understates Phase 4. Conversely it does not capture the authz/persistence caveats. (Roadmap checkboxes are an unreliable completion proxy in both directions.)
5. **Realtime contract** previously listed `message_updated`/`message_deleted` server events before they existed (corrected in a prior slice; now implemented).
6. **Prior SESSION_LOG "48 excluded" figure** is now **50** (socket-auth slice added 2 pg-integration tests).
