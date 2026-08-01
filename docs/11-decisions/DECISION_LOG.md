# Decision Log

Architecture decisions, newest first. Each entry: context → decision → rationale → status.

## [2026-08-02] Search restored — and "an index, not a shadow" retired as a framing

- **A tsvector is a lossy but READABLE copy of message content, and calling it an index does not make
  it not-a-copy.** The flip decision named a "rebuildable tsvector INDEX (an index, not a shadow
  store)" as the way back to search. Measured before building on it, and the framing did not survive:
  `to_tsvector('english', 'Meet me at the Hilton on Baker Street at 7pm, bring the passport')` stores
  `'7pm':10 'baker':7 'bring':11 'hilton':5 'meet':1 'passport':13 'street':8` — every content word in
  plaintext, WITH POSITIONS, so word order is recoverable, and `ts_stat` enumerates them straight back
  out. What is lost is stopwords, casing and punctuation. The honest claim we would have to stand
  behind is **"the index contains the words but not the message" — and the words are enough**.
- **It also costs MORE than the text it derives from:** on realistic chat prose, 200k messages →
  bodies 6,982 kB, tsvector column 10,010 kB (**1.43×**), plus the GIN index. There is no version of
  this where the derived structure is the lightweight option.
- **The operational properties are real and worth having** — rebuildable from Scylla, never
  authoritative — and they are what distinguish it from a body shadow OPERATIONALLY. They are not a
  privacy argument, and must not be used as one.
- **Therefore commits 3 (tsvector column + GIN) and 4 (rebuild from Scylla) STAY UNBUILT.** They wait
  on an explicit, recorded decision that MESSAGE TEXT LIVES IN POSTGRES. **The honest trigger for
  making that decision is dual-write ending — not a calendar.**
- **What shipped instead, and why it works today:** under `scylla_read`, reads come from Scylla but
  WRITES ARE STILL DUAL — the rollback insurance keeps `messages` complete and current. So search is
  served from Postgres with no new store, no new write path and no index. **This dies when dual-write
  ends**, and that expiry is recorded in `PostgresAdapter.search_messages/1` itself, where whoever
  turns dual-write off will read it — not only here.
- **It is a PRIVACY FIX, not a restoration.** The old search filtered on participation and
  `status <> 'deleted'` and nothing else: it returned hits for messages the searcher had CLEARED, that
  had aged out of their auto-delete window, or that carried a permanent hidden marker. Turning the old
  query back on would have restored a privacy bug. Every visibility mechanism is now applied, composed
  from ONE definition (`MessageService.VisibilityWindow`) that `InboxProjection` — which carried the
  predicate longhand twice — now shares.
- **Also found and fixed en route (see 79cfdeb):** the capability error this log promised was never
  delivered. `:message_store_unavailable` (what the store returns) and `:message_unavailable` (what
  ~35 gateway clauses match) were near-synonyms with nothing mapping between them, so search returned
  **400** and the web client rendered it as "No results" — the exact silent empty list this log
  forbade. The same mismatch meant a live Scylla outage returned 400 on every message endpoint,
  defeating the rollback drill's own normalization fix. Measured, not reasoned.

## [2026-08-01] C6 — webhook outbox write-ahead intent: the promise, restated precisely

- **What the old guarantee actually was (verified in code before writing this):** the same-transaction
  `emit` guaranteed the outbox ROW's existence atomically with the message — atomicity of the
  ENQUEUE. Delivery was ALWAYS at-least-once: `claim_due` uses a visibility timeout, so a worker
  dying mid-delivery re-POSTs an already-received event; retries reuse the stable `event_id`. The
  C6 weakening is therefore narrower than "exactly-once is gone": exactly-once never existed for
  delivery; what is given up is enqueue atomicity, on the Scylla path only.
- **The mechanism:** stage (durable Postgres intent, status='staged', invisible to the dispatcher)
  → Scylla put → promote ('pending', guarded by status='staged' — idempotent by construction, and
  no path ever inserts a second row for the same intent). Synchronous put failure aborts the staged
  rows immediately with the reason. A CRASH between put and promote strands rows the
  WebhookOutboxSweeper resolves each interval (60s default): message present → promote; message
  ABSENT (the store answered) → abort; store UNREACHABLE → leave staged, never abort on an outage.
- **Abort is KEPT-AND-MARKED, not deleted:** an aborted row is evidence a write was attempted and
  lost. Operators see it via `SELECT * FROM webhook_outbox WHERE status='aborted'` (last_error names
  the cause); the row is the record, or can be re-driven manually (status='pending') if the message
  was repaired into existence. Migration 087 extends the status CHECK with 'staged'/'aborted'.
- **Proven live, not reasoned (ScyllaWebhookOutboxTest):** the crash window is reproduced literally
  (stage + put, promote skipped) — sweep promotes exactly once, a second sweep and a direct
  re-promote are no-ops, the row is claimable exactly once; abort keeps and marks; an unreachable
  store leaves rows staged.
- **The contract lives where integrators read it** (INTEGRATION_GUIDE §7): at-least-once delivery
  (unchanged, and never was exactly-once), dedupe on `x-webhook-event-id`, crash-window enqueue lag
  bounded by sweep interval + stale window (~2 min worst case, default config).

## [2026-08-01] Inbox denormalisation (086) + the port ladder — pressure-tested and reordered

- **Context:** the Scylla port's §0.5 inbox fork. Chosen (over Scylla-side fan-out, read-composition,
  and a Postgres shadow): DENORMALISE THE INBOX ROW — maintained columns instead of read-time laterals
  over `messages`. Pressure-tested before building; two amendments were load-bearing:
  - **the global-preview split** — preview facts live on `conversations` (per-user variation is a
    read-time MASK over the participant's own prefs; the newest message is always the last to leave
    any window, so no older-message fallback exists), and only `unread_count` is per-participant.
    Halves the write fan-out and makes edit/delete a one-row update.
  - **`oldest_unread_at` + read-repair** — a maintained counter cannot decay as a rolling auto-delete
    window moves (messages age out with no write anywhere). The watermark makes freshness PROVABLE;
    stale rows get an inline recount at read time, persisted back.
- **Deliberate: the watermark is NOT advanced on mark_read.** Advancing would need a store read per
  receipt to find the next-oldest unread. Stale is SAFE (fails the freshness test → recount → repair);
  auto-delete conversations pay an occasional extra recount for it. The one free advance: a decrement
  reaching 0 NULLs it. Marked in InboxProjection's moduledoc — do not "fix" without reading this.
- **Accepted drift, corrected not prevented:** the decrement is not idempotent under double-delivered
  receipts, and cross-store partial failure becomes possible once messages move to Scylla. Exactness
  would cost per-(message,user) dedup state in Postgres (receipts-in-Postgres again) or LWT per
  receipt. Instead: clamp at 0, window-guarded decrements, and the MANDATORY `InboxReconciler`
  (recently-active conversations, every 5 min) — which doubles as C7's dual-write comparator.
- **Reordered ladder — C5 (this) FIRST:** it is the only rung with value independent of the port —
  the inbox (the app's most-used screen) stops running 2 laterals x 500 conversations per open and
  2 laterals x N recipients per message send (the conversation_updated frames already did that at
  write time), Postgres store or not. Confirmed free of C2–C4 dependencies (the delete-path
  next-newest read is adapter-local). Remaining: C2 core-13, C3 media CQL, C4 the six + oracle
  battery, C6 outbox write-ahead intent, C7 dual-write + backfill, C8 shadow-read + flip + rollback
  drill.
- **SEARCH — a product regression accepted with eyes open:** at flip, cross-conversation message
  search on web STOPS WORKING and returns a capability error (`search.unavailable`, never a silent
  empty list). Android is unaffected (searches Room locally); web is the only caller of
  `/api/v1/search/messages`. **This is a feature users can currently use, disappearing.** It is
  acceptable because there are no external users yet — **and that reason EXPIRES the moment there
  are.** A capability error is a fine engineering answer and a poor product one: if external users
  exist before the flip, a rebuildable non-authoritative Postgres search INDEX (tsvector, derivable
  from Scylla at any time — an index, not a shadow store) must ship first. Whoever schedules the flip
  needs both halves of this.

## [2026-08-01] Scylla full port (Option A): design accepted, commit 1 built, the rest deliberately unbuilt

- **Context:** Option A (full message-store port) was designed. Reading the adapter before designing
  changed the premises materially: the "core 13" was actually **7 functions that had never executed a
  single CQL statement against a real engine + 6 explicit stubs** (reactions, stars, search), the 7
  carried guaranteed Phase-D type errors (ISO strings against `date`, nested maps against
  `map<text,text>`), `get_message` was a list-200-and-find, and `list_messages` returned
  `next_cursor: nil` unconditionally. Scope grew materially once the adapter was actually read:
  **7 unverified + 6 stubs + 6 unported + an inbox that reads messages from another service.**
- **Built (commit 1 — "make the existing surface real"):** the Phase-D codec with the uniform
  metadata-JSON convention (every metadata value stored as its JSON encoding — stated in the CQL file
  header, `ScyllaCodec`, and enforced by a live round-trip of a nested poll definition);
  bucket-derived point reads (timeuuid → bucket, previous-day candidate for the midnight race); real
  cursor pagination (per-bucket queries merged client-side — the first live run against a real engine
  caught that `LIMIT` + multi-partition `IN` truncates in token order before any client-side sort,
  which a fake can never catch); `scripts/test-scylla.sh` + a CI step running every `@tag
  :scylla_integration` suite against a real Scylla; a CQL drift test mirroring the Postgres one.
  The adapter stays unselected; production stays Postgres.
- **The two findings that make this a re-architecture rather than a port (verbatim from the design):**
  - *"The inbox reads the messages table directly, from another service. `conversation_service`'s
    `@inbox_sql` laterals over `messages` for the preview and the unread count — honouring
    `cleared_before`, `auto_delete_seconds`, and read receipts, per participant. If messages leave
    Postgres, the inbox breaks. The unwired `messages_by_user_inbox` table exists for this, but
    maintaining it means per-recipient fan-out (256 read-modify-writes per group message — Scylla
    `int`, not a counter, and the unread logic would need reimplementing against per-user windows)."*
    The alternatives — inbox projection fan-out in Scylla, conversation_service composing
    preview/unread from Scylla at read time, or a Postgres shadow (dual-store by another name) — are
    an undecided checkpoint. **Read this before considering the port.**
  - *"`put_message` is a transactional outbox. Message insert + `webhook_outbox` rows commit as one
    Postgres transaction — that's the no-lost-webhook guarantee. With messages in Scylla there is no
    shared transaction: a Scylla-committed message whose outbox insert fails emits no webhook (or
    vice versa). The guarantee degrades to at-least-once with reconciliation, and that must be stated
    as a weakened contract, not discovered later."*
- **Deliberately unbuilt:** the six optional callbacks (media trio / message_info / polls — designed:
  two new CQL tables, cross-store composition, poll validation via Scylla point-read with votes
  staying Postgres), the inbox decision, dual-write + backfill + shadow-read + cutover, and
  `search_messages` (no honest Scylla answer; ILIKE-over-participants needs a body shadow or external
  search — its own decision).
- **Trigger — unchanged:** flip only when `list_messages` latency or Postgres write throughput is a
  MEASURED bottleneck (the slice-49 profiling standard). The adapter seam keeps the option open at
  zero carrying cost; commit 1 just made the seam real instead of load-bearing fiction.

## [2026-08-01] ScyllaDB position: hybrid end-state, measured trigger — not a scheduled migration

- **Context:** Phases A and B shipped (container + schema behind the `scylla` compose profile; a real
  Xandra driver behind the client boundary). `MESSAGE_STORE_ADAPTER` is `postgres` and the profile is
  off, so **nothing runs today and it costs nothing**. Phase D (type encoding — bucket_date/timestamp/
  metadata vs the CQL column types) remains the prerequisite before the adapter can flip.
- **What changed since the plan:** `message_store.ex` now carries seven relational joins that did not
  exist when the Scylla schema was designed — receipt reciprocity (`user_privacy_settings`, twice),
  the media download oracle (`conversation_participants`), stars, and the poll/receipt aggregates.
  None of that is Scylla-shaped, and it would stay in Postgres.
- **Decision:** the eventual shape is a **HYBRID** — message CRUD in Scylla, relational satellites
  (receipts-with-privacy, media authz, polls, stars) in Postgres — not a migration. "We're moving
  messages to Scylla" now under-describes the work and should not be said.
- **Trigger:** do **not** flip on a schedule. Flip when `list_messages` latency or Postgres write
  throughput is a **measured** bottleneck, profiled the way slice 49 profiled the Android client.
  Until then the adapter seam is the whole point: it keeps the option open at zero carrying cost.
- **Status:** dormant by design. See `docs/09-devops/SCYLLA.md` for the operational detail.

## [2026-07-26] Privacy settings enforcement + first-party presence broadcast fix

- **Context:** privacy settings existed as a table + placeholder read, unexposed and unenforced; and
  first-party (web/Android) users never got LIVE presence — `RealtimeGateway.UserPresence.broadcast_presence`
  skipped any target with no integrator external id.
- **Decision — real privacy** (`UserService.Privacy` reads the store + sparse validated update; `GET/PATCH
  /api/v1/privacy`), enforced server-wide: `last_seen_visibility` in `SharedInfra.PresenceAuthz.can_see?`,
  `profile_photo_visibility` folded into the avatar-serving paths' `avatar_hidden?`, `read_receipts_enabled`
  at the live tick + `read_by_count`.
- **Decision — `everyone` ≠ `contacts`** for last_seen (was collapsed): a setting named "everyone" that
  behaves like "contacts" is a lie to the user. Default stays "contacts"; only users who explicitly chose
  "everyone" are affected, and presence is still queried per-id.
- **Decision — read-receipt reciprocity at BOTH surfaces:** live tick (`receipt_updated`, DM two-party gate /
  group emit-only, resolved once at join) AND load `read_by_count` (a reader who disabled is excluded via a
  JOIN; a viewer who disabled sees 0). The reader's own receipt is STILL persisted (it drives their unread
  count); only its EXPOSURE is filtered.
- **ACCEPTED, DOCUMENTED inconsistency (do not mistake for a bug):** in a GROUP, a member who disabled read
  receipts still sees OTHER members' live receipt ticks until the next load, where the `read_by_count` filter
  correctly removes them. The live per-recipient delivery-suppression is DM-only — under topic-wide
  `broadcast_from`, per-recipient live suppression in a group is disproportionate, and WhatsApp itself exempts
  groups from the reciprocal rule. The load-path filter makes it eventually consistent on refresh. Proportionate
  and deliberate.
- **Decision — presence audience** (`:presence_audience` on the socket): the internal-keyed `presence:<id>`
  topic is shared by /v1 (external ids) and first-party (internal ids). `broadcast_presence` now ALWAYS
  broadcasts a visible transition (frame carries both ids); subscribe + delivery are audience-aware — /v1
  strips `internal_id`, first-party keeps it. No internal uuid ever reaches an integrator.
- **Status:** Implemented + tested. Docker-free suites green across affected apps; the store CRUD +
  read_by_count reciprocity are `@tag :postgres_integration`. No new compile warnings.


## [2026-07-26] User blocking + first-party reporting (Tier-2 safety)

- **Context:** blocking didn't exist; reporting was half-built (the `user_reports` table + the admin read
  existed, but no user-facing create). Both are cross-cutting — a block that only hides the UI is worthless.
- **Decision — `user_blocks` owned by conversation-service** ([ConversationService.Blocks](../../apps/backend/apps/conversation_service/lib/conversation_service/blocks.ex),
  migration [075](../../infra/docker/postgres/init/075_user_blocks.sql)), exposed via `SharedInfra.ConversationClient`.
  The hottest enforcement — the per-message send gate ([`Participants.authorize_send`](../../apps/backend/apps/conversation_service/lib/conversation_service/participants.ex))
  — already runs there, so the block check is a LOCAL indexed query: no cross-service round-trip, **no cache**.
  realtime-gateway (calls/presence) + the gateway (profile/endpoints) have no Repo and reach it via the client.
  Reports create lives with the existing moderation reads ([`AuthService.Moderation.create_report`](../../apps/backend/apps/auth_service/lib/auth_service/moderation.ex)),
  so the admin console picks new rows up unchanged.
- **Decision — either-direction (symmetric) semantics** (`either_blocked?/1`): a block severs the 1-on-1
  channel BOTH ways, which is coherent and can't be probed to reveal which side blocked.
- **Decision — messages use DROP-AT-CREATE with a synthetic success**, not accept-and-drop-at-fan-out. For a
  DIRECT chat the recipient blocked, the send gate returns `delivery: "drop"`; the sender gets a CANONICAL
  single-tick ack ([`Messages.synthesize_dropped`](../../apps/backend/apps/message_service/lib/message_service/messages.ex))
  and NOTHING is persisted/published/fanned. One decision point, zero leak surface — the message never exists
  server-side, so no fan-out leg, timeline read, reconnect catch-up, or push can leak it to the blocker.
- **ACCEPTED TRADE-OFF (do not mistake for a bug):** because a blocked-DM message is never persisted, it is
  ABSENT FROM THE SENDER'S OWN SERVER HISTORY. On a fresh install or a second device, the sender's
  messages-sent-while-blocked do not appear (the client keeps only its local optimistic echo). This is a
  deliberate-probe signal — a determined sender could infer a block by noticing their sent messages don't
  sync. We accept it: the alternative (persist + filter the blocker's every read/catch-up/fan-out leg) trades
  a faint probe signal for a large silent-leak surface, and leaking the message to the blocker is the worse
  failure for a safety feature. Single-device senders never notice.
- **Enforcement points:** messages (drop at `authorize_send`); calls (ring + FCM push suppressed in
  `CallSignaling.ring_callee`, AND the missed pill suppressed in `write_missed_message` so reject/cancel/timeout
  all leave nothing in the blocker's chat); presence (`SharedInfra.PresenceAuthz.can_see?`, both directions,
  subscribe + read); profile/by-phone (avatar redacted, account still exists, never leaks "blocked"); typing/
  "viewing" (gated at join via `direct_peer_blocked?`). NOT over-applied to groups — a blocked user still
  posts to a shared group and the blocker sees it.
- **Reports:** `POST /api/v1/reports` — reason ∈ {spam,harassment,impersonation,other}, details capped 2000,
  per-reporter rate-limited (`SharedInfra.RateLimiter`). "Report and block" = two client calls, no combined
  endpoint.
- **Status:** Implemented + tested. Docker-free suites green across all affected apps (message_service 68,
  shared_infra 96, conversation_service 25, api_gateway block/report/profile/message-drop + typing/call suites);
  block/report SQL + the create_report→list_reports round-trip are `@tag :postgres_integration` (DB-gated). No
  new compile warnings. Pre-existing offline-env failures (placeholder-path + DB-backed channel tests + one
  `PushSubscriptionsTest`) are unrelated (confirmed against a stashed baseline).

## [2026-06-24] Demo/echo OTP delivery mode for local testing (flag-gated, default-off)

- **Context:** completing an OTP login locally needs the code, but it's SMS-only + stored hashed
  (unrecoverable) — so local frontend testing was blocked without a real DLT phone. Added a flag-gated way
  to obtain the code without SMS.
- **Decision — `OTP_DELIVERY_MODE` env (default `"none"`)**, independent of `OTP_SMS_DELIVERY_ENABLED`:
  `"echo"` injects the plaintext code into the OTP-request response as `debug_code`
  ([otp_delivery.ex `echo_code/2`](../../apps/backend/apps/auth_service/lib/auth_service/otp_delivery.ex), wired in
  `request_persisted_otp`); `"log"` `Logger.warning`s it (not in the response); `"none"` surfaces nothing
  (prod-safe default — hashed, never exposed). Local demo = SMS off + `OTP_DELIVERY_MODE=echo`. Read via
  `config :auth_service, otp_delivery_mode` ([config.exs](../../apps/backend/config/config.exs)).
- **Decision — LOUD prod guard (no crash):** `@compiled_env Mix.env()`; if `:prod` AND mode ∈ {echo,log},
  `Logger.error` a prominent once-per-VM warning that plaintext OTP exposure is on (private staging ONLY, never
  real users). Doesn't fail boot — warns.
- **Status:** Implemented + verified. `mix compile --warnings-as-errors` clean; plain `mix test` **284/91**
  (281 + 3), Docker-free — **default `"none"` → zero behavior change** (existing flows + any deploy without the
  env unaffected). Tests: echo→`debug_code` in response; none/default→absent (safety); log→logged, not in
  response. echo/log are LOCAL/STAGING ONLY; production = `"none"` + real SMS.

## [2026-06-24] Deploy 3b — self-hosted host config (.env-driven) + runbook

- **Context:** with both code blockers closed (schema-load + OTP delivery), the only gaps to a self-hosted run
  were host-specific values hardcoded in the compose (`PHX_HOST: localhost`) and the SMS envs not wired.
- **Decision — make host config `.env`-driven, no compose edits per deploy:** `PHX_HOST: ${PHX_HOST:-localhost}`
  + `WEB_ORIGIN: ${WEB_ORIGIN:-}` in the `x-secrets` anchor ([docker-compose.prod.yml:21](../../docker-compose.prod.yml#L21));
  the 6 SMS envs (`OTP_SMS_DELIVERY_ENABLED` default false + `SMS_GATEWAY_HUB_*`/`SMS_ENTITY_ID`/`SMS_TEMPLATE_LOGIN_ID`)
  added to the **auth** container only — auth_service owns the OTP request path; the gateway proxies over HTTP and
  its release doesn't even include auth_service, so SMS config there would be dead. All from `.env`, nothing
  hardcoded.
- **Decision — self-hosted runbook in DEPLOYMENT.md** (server prereqs, `.env` template, `up -d --build`, verify,
  frontend URLs, first-login smoke test, TLS-proxy note, DLT-6-digit + key-rotation pre-flight). Schema auto-loads
  via the postgres initdb mount (load_schema is the Fly/managed-PG path, moot for compose).
- **Status:** Compose config valid with a sample `.env` (PHX_HOST interpolates across all 8 services; SMS envs on
  auth, NOT gateway — verified). `mix compile --warnings-as-errors` clean; plain `mix test` **281/91** unchanged
  (config + docs only). Stack is deploy-ready; the operator provisions a box, fills `.env`, `up -d`, logs in.

## [2026-06-24] OTP delivery via SMSGatewayHub (DLT) — last login blocker closed

- **Context:** the readiness check flagged TWO deploy-3b blockers — schema-load (closed prior) and **OTP
  delivery**: `request_otp` hashed + stored the code but never sent it (and it's unrecoverable from the DB), so
  no human could log in. This wires real SMS delivery via the user's DLT-registered SMSGatewayHub account.
- **Decision — `AuthService.SmsClient`** ([sms_client.ex](../../apps/backend/apps/auth_service/lib/auth_service/sms_client.ex)):
  `send_otp/2` POSTs to SMSGatewayHub `/api/mt/SendSMS` with QUERY-STRING params (`APIKey, senderid, channel,
  DCS, flashsms, number, text, route, EntityId, templateid`) via **Req directly** (NOT `SharedInfra.HttpClient`
  — that injects internal headers + decodes our result-envelope, wrong for a 3rd-party API; added
  `{:req, "~> 0.5"}` to auth_service). `text` = the DLT-approved LOGIN template verbatim,
  `"Dear user, your login OTP is #{code} 1500BC"` (a mismatch is provider ErrorCode 024). Success =
  `ErrorCode == "000"`; any other → `{:error, {code, message}}` logged; transport failure → `{:error,
  :sms_unavailable}`; never raises. `format_number/2` bridges a bare 10-digit number to country-code form
  (`91…`, prefix env-configurable) since `normalize_destination` only trims.
- **Decision — `AuthService.OtpDelivery`** ([otp_delivery.ex](../../apps/backend/apps/auth_service/lib/auth_service/otp_delivery.ex)):
  `deliver(destination, code, method)` — SMS via SmsClient when enabled; email is a no-op (future channel).
  Hooked into `request_persisted_otp` AFTER a successful `create_verification_code`; `prepare_request` now
  surfaces the plaintext `code` + `destination` in an INTERNAL `delivery:` map (never in the public `response`
  or the DB).
- **Decision — resilience (a):** a delivery failure is LOGGED loudly but does NOT fail OTP creation — the code
  is persisted, so the user can resend (fire-and-forget, mirroring the Kafka producers). Stated over surfacing a
  delivery error, for resilience.
- **Decision — config + flag** ([config.exs](../../apps/backend/config/config.exs) `config :auth_service, :sms`):
  env-driven, **DEFAULT OFF** (`OTP_SMS_DELIVERY_ENABLED`), so plain `mix test` + existing flows never call out.
  Secrets (`SMS_GATEWAY_HUB_API_KEY`, `SMS_ENTITY_ID`, `SMS_TEMPLATE_LOGIN_ID`, `SMS_GATEWAY_HUB_ROUTE`) are env
  only — never hardcoded; fixed OTP values `senderid=ISOOBC`, `channel=2`, `DCS=0`, `flashsms=0`.
- **⚠️ OTP length note:** the app generates **6-digit** OTPs (`@default_code_digits 6`, [otp.ex:17](../../apps/backend/apps/auth_service/lib/auth_service/otp.ex#L17)); the DLT
  `{#var#}` variable normally accepts any length, but the registered LOGIN template should be confirmed to accept
  6 digits (else ErrorCode 024). NOT changed here (the code length is a product decision).
- **Status:** Implemented + verified. `mix compile --warnings-as-errors` clean; plain `mix test` **281/91**
  (274 + 7: SmsClient 4 + OtpDelivery 3), Docker-free — **delivery off by default + Req `plug:` stub so the REAL
  provider is NEVER called in tests/CI**. Tests prove: correct params + verbatim DLT text + `000→:ok` /
  `024→{:error,…}`; flag-off → no provider call (safety default); number normalization. **Closes deploy-3b
  blocker #1** — a human can log in once the flag is on + secrets set on the host. Email delivery remains a
  separate future channel. The real send happens only on the deployed host (flag on + secrets); not exercised in
  CI by design.

## [2026-06-24] Release schema-load task for managed Postgres (deploy blocker closed)

- **Context:** the schema is RAW SQL (`infra/docker/postgres/init/001..042`), NOT Ecto migrations, and there
  is no release task. The compose path auto-loads via `docker-entrypoint-initdb.d`, but a managed Postgres (a
  fresh Fly Postgres) comes EMPTY — and the slim release image has no `psql`. One of the two deploy-3b blockers
  (the readiness check flagged this + OTP delivery).
- **Decision — `SharedInfra.Release.load_schema/0`** ([release.ex](../../apps/backend/apps/shared_infra/lib/shared_infra/release.ex)),
  runnable via `bin/chat_platform eval "SharedInfra.Release.load_schema()"`: `ensure_all_started(:postgrex)`,
  parse `DATABASE_URL`, read `priv/schema/*.sql` in numeric order, run each (strip line comments, split on `;`
  — SAFE: the schema is plain DDL, no `$$`/functions/triggers), log each file. Uses **Postgrex** directly (no
  psql in the image; no Ecto Repo needed). Idempotent — every statement is `CREATE … IF NOT EXISTS`, so a
  re-run is a safe no-op (proven).
- **Decision — SQL into the release via `priv` (a kept-in-sync COPY), NOT relocation.** The Docker build context
  is `apps/backend`, so `infra/docker/postgres/init` (repo root) is OUTSIDE it and can't be `COPY`d; and that
  path is referenced by the compose initdb mount + CI + several **historical** docs, so relocating it would
  rewrite history. Instead the SQL is copied to `apps/backend/apps/shared_infra/priv/schema/` (priv ships in
  every release, readable via `Application.app_dir/2`). `infra/…/init` stays canonical; a drift-guard test
  ([release_schema_drift_test.exs](../../apps/backend/apps/shared_infra/test/shared_infra/release_schema_drift_test.exs))
  asserts the two are byte-identical so they can't diverge silently. Added `{:postgrex, "~> 0.17"}` to
  shared_infra (already in the lock via ecto_sql).
- **Deploy order:** provision managed Postgres → `fly secrets set` the secrets + `fly postgres attach`
  (DATABASE_URL) → `bin/chat_platform eval "SharedInfra.Release.load_schema()"` (run-once on the fresh DB) →
  boot the server.
- **Status:** Implemented + verified. `mix compile --warnings-as-errors` clean; plain `mix test` **274/91**
  (273 + the drift-guard test; existing 273 intact, Docker-free). **Local proof** (real): built the
  `chat_platform` prod release, ran a throwaway EMPTY `postgres:16`, `bin/chat_platform eval load_schema()` →
  0 tables → all 7 files applied in order (logged) → **36 tables**; an **idempotent re-run** → still 36, no
  error; key tables (`users_auth`/`user_profiles`/`notifications`/`conversation_participants_readmodel`)
  present. One deploy blocker (schema-load) CLOSED; **OTP delivery remains** (the other blocker — arrives with
  the Mailpit/gateway slice).

## [2026-06-24] MinIO into the compose stack — media object storage (compose stack feature-complete)

- **Context:** the last staged-OFF infra piece. media ran on the default `QueryPlanAdapter`; real object
  storage needs MinIO + the `chat-media` bucket. Orthogonal to the event backbone; additive to the proven core.
- **Decision — compose ([docker-compose.prod.yml](../../docker-compose.prod.yml)):**
  - `minio` (minio/minio; [:237](../../docker-compose.prod.yml#L237)) — **internal-only** (`expose`, no host
    publish): services reach it at `minio:9000`; avoids clashing with the dev infra compose's minio on 9000/9001.
    `curl` healthcheck on `/minio/health/ready` (the image bundles curl + mc — verified). `minio_data` volume.
    (minio/minio is the S3-API image; no relocated-namespace concern, unlike `bitnamilegacy` kafka.)
  - `minio-init` ([:256](../../docker-compose.prod.yml#L256)) — one-shot reusing the minio image's bundled `mc`:
    `mc alias set` + `mc mb --ignore-existing local/chat-media`, then exits 0. The dev compose never created the
    bucket; this does. `depends_on minio: healthy`.
  - media flipped to object storage ([:138](../../docker-compose.prod.yml#L138)): `MEDIA_STORAGE_ADAPTER=minio`
    ([config.exs:175](../../apps/backend/config/config.exs#L175) selects `MediaService.Storage.MinioAdapter`),
    `MINIO_ENDPOINT=http://minio:9000`, bucket `chat-media`, creds `minioadmin`, `MINIO_PATH_STYLE=true`.
    `depends_on` rewritten to **postgres healthy + minio-init completed** (spelled both, since `<<: *service-base`
    shallow-overrides the anchor's depends_on) so the bucket exists before media serves uploads.
- **Status:** Implemented + verified. Fast `mix test` **273/91** Docker-free UNCHANGED (MinIO not required; the
  `MinioAdapter` presign tests at media_test.exs:118-167 are plain unit tests, already counted); compose config
  valid; no Elixir code changed. **Live e2e** (full stack `up --build --wait`): minio healthy, minio-init exited
  0, `chat-media` bucket present; `mc cp` a 28-byte object → `mc stat`/`mc cat` returned it byte-identical —
  deterministic proof the container's MinIO wiring (endpoint, bucket, creds) works; media booted with the
  MinioAdapter, no crash; teardown clean. **The compose stack is now feature-complete** (postgres + 5 services +
  gateway + kafka/kafka-init/notification + minio/minio-init).
- **Deferred (recorded):** the gateway→media→MinIO **authed presign+upload** path is not exercised here (the
  authed media route needs OTP/Mailpit, same scoping as the Kafka slice). Covered by media's existing presign
  unit tests. Folds into the future Mailpit slice. (MinioAdapter only *generates* presigned URLs; clients
  PUT/GET directly to MinIO — the `mc` round-trip proves that path's storage end.)

## [2026-06-24] Kafka event-backbone + notification_service into the compose stack

- **Context:** the compose stack ran core chat only (Kafka/MinIO staged OFF), and notification_service —
  a pure Kafka consumer — had neither a per-service release nor a container. Bring the event backbone +
  notification into `docker-compose.prod.yml`, and close the deferred consumer-correlation guards now that a
  live broker exists. MinIO stays a separate slice.
- **Decision — compose ([docker-compose.prod.yml](../../docker-compose.prod.yml)):**
  - `kafka` (KRaft, no zookeeper; [:147](../../docker-compose.prod.yml#L147)) — **internal-only** (`expose`, no host
    publish): a prod broker shouldn't be host-exposed, and it avoids clashing with the dev infra compose's kafka
    on 9094. Services reach it at `kafka:9092`. Healthcheck = `kafka-topics.sh --list`. **TODO:** `bitnamilegacy/*`
    is Bitnami's relocated namespace — revisit for a real prod registry.
  - `kafka-init` ([:182](../../docker-compose.prod.yml#L182)) — one-shot reusing `topics.env`/`create-topics.sh` to
    create topics at their **declared partition counts** (message.events.v1 = 6) before any produce/consume.
    NOT `AUTO_CREATE` — `:hash` keying needs a stable partition count. `depends_on kafka: healthy`, then exits 0.
  - `notification` ([:201](../../docker-compose.prod.yml#L201)) — `RELEASE=notification_service`, both consumer
    flags on, **no published port** (pure consumer). `depends_on postgres: healthy + kafka-init:
    service_completed_successfully` (topics exist before it joins; `begin_offset: :latest` ⇒ it must be joined
    before events are produced).
  - message/conversation: `KAFKA_PRODUCER_ADAPTER=brod` + the publish flag + `KAFKA_BROKERS=kafka:9092`.
    **DISCOVERY:** `KAFKA_PUBLISH_ENABLED`/`CONVERSATION_PUBLISH_ENABLED` alone leave the adapter on
    `NoopProducer` ([config.exs:167](../../apps/backend/config/config.exs#L167)) — `KAFKA_PRODUCER_ADAPTER=brod`
    is ALSO required to actually emit (and to start the brod client at boot). Producing stays fire-and-forget, so
    core message creation succeeds even if the broker is down → core deps unchanged (postgres only), additive.
- **Decision — per-service release ([mix.exs:59](../../apps/backend/mix.exs#L59)):** `notification_service:
  [shared_infra, notification_service]`, mirroring the others; assembles lean.
- **Decision — deferred consumer-correlation guards (review findings 1 & 2) CLOSED:** all 4 consumers emit
  `{:consumer_correlation, SharedInfra.Correlation.get()}` after `Correlation.put(envelope["correlation_id"])`
  ([e.g. conversation_participants_consumer.ex:97](../../apps/backend/apps/notification_service/lib/notification_service/events/conversation_participants_consumer.ex#L97));
  the 3 consumer `kafka_integration` tests assert it with a PINNED expected value (the topic is shared, so a
  bound match would race on stray events). **3/3 pass over a live broker** — deterministic proof the consumer
  extracts correlation_id into its process Logger metadata.
- **Status:** Implemented + verified. Fast `mix test` **273/91** Docker-free UNCHANGED (Kafka not required);
  `mix compile --warnings-as-errors` clean; notification release assembles lean; compose config valid (10
  services); `kafka_integration` guards 3/3 over the live dev broker. **Live e2e** (prod stack `up --build
  --wait`, direct broker produce): participant_added(sender+recipient) → read-model → message.created (known
  correlation_id) → **exactly one notification row for the recipient, sender excluded** — real cross-network
  fan-out through the notification container (JSON logs show it joined `notification-service-message-created`,
  `begin_offset=:latest`); teardown clean.
- **Known limitations (recorded):**
  1. `SharedInfra.Logging.JsonFormatter` renders brod's charlist metadata (e.g. `file`) as int arrays — valid
     JSON, key fields (`message`/`level`/`time`/`correlation_id`) clean; cosmetic-only. Minor follow-up:
     printable-charlist heuristic.
  2. The gateway→broker→notification FULL path is not exercised here (direct broker produce; the gateway-authed
     message path needs OTP/Mailpit). Covered by existing `kafka_integration` producer + unit tests; full path
     deferred to a future Mailpit slice.

## [2026-06-24] Observability — correlation_id end-to-end + prod JSON structured logs

- **Context:** the public error envelope carried a literal `"corr_placeholder"` (audit-flagged) — no real
  trace. A single id should follow a request gateway → internal HTTP → every service → Kafka events → consumers,
  with structured logs so it's queryable.
- **Decision — carrier = Logger metadata (`:correlation_id`) + `x-correlation-id` header across boundaries.**
  New `SharedInfra.Correlation` (generate via `:crypto`, NOT Ecto — `shared_infra`/`api_gateway` have no ecto
  dep; `valid?/1` length+blank guard) is the single helper.
- **Gateway origin:** `ApiGatewayWeb.Plugs.CorrelationId` ([endpoint.ex:9](../../apps/backend/apps/api_gateway/lib/api_gateway_web/endpoint.ex#L9),
  right after `Plug.RequestId`) honors a sane inbound `x-correlation-id` else mints one; sets Logger metadata +
  `conn.assigns[:correlation_id]` + echoes the response header. `error_response.ex` emits the real id via
  `correlation_id(conn)` ([:20 et al.](../../apps/backend/apps/api_gateway/lib/api_gateway_web/controllers/error_response.ex#L20))
  — **`corr_placeholder` removed; envelope SHAPE byte-identical** (only the value is real).
- **Internal HTTP:** `SharedInfra.HttpClient.headers/0` appends `x-correlation-id` from Logger metadata when set,
  OMITS it when absent ([http_client.ex:115](../../apps/backend/apps/shared_infra/lib/shared_infra/http_client.ex#L115));
  `SharedInfra.InternalApi.CorrelationPlug` reads it back into Logger metadata on **all 5** service routers.
- **Kafka (the careful part):** producers capture `SharedInfra.Correlation.get_or_generate()` SYNCHRONOUSLY in
  the caller BEFORE `Task.start` and thread it into the envelope build
  ([messages.ex:142](../../apps/backend/apps/message_service/lib/message_service/messages.ex#L142),
  [participant_events.ex:84](../../apps/backend/apps/conversation_service/lib/conversation_service/participant_events.ex#L84))
  — reading metadata inside the async closure would see the Task's empty metadata and lose the trace. All **4**
  consumers `SharedInfra.Correlation.put(envelope["correlation_id"])` at decode, so the message.created → fan-out
  chain shares one id.
- **Structured logs:** hand-rolled `SharedInfra.Logging.JsonFormatter` (no new dep — uses Jason; defensive, never
  raises), wired PROD-ONLY ([prod.exs:12](../../apps/backend/config/prod.exs#L12)); dev/test keep the plain console
  format; `:correlation_id` added to the metadata whitelist in all envs ([config.exs:38](../../apps/backend/config/config.exs#L38)).
- **Adversarial review (`wf_13d7d1a9-bb6`, 6 dimensions):** 5/6 returned ZERO findings (completeness,
  async-capture, public-contract, security, config-logging). The only findings were test-coverage gaps; the two
  verified ones were FIXED (gateway blank-header now asserts resp-header + metadata; added an oversized-inbound
  `>200`-byte test).
- **DEFERRED (recorded so it's not lost):** Kafka consumer correlation→metadata regression guards (review
  findings 1 & 2) — asserting the consumer's per-process metadata needs echoing it through the consumers'
  test-notification (~5 edits across the 4 consumers + their `kafka_integration` tests, only runnable with a live
  broker). Deferred to the Kafka/MinIO staged-re-enable + notification_service-container slice. The extraction
  itself is the unit-tested `Correlation.put/1`.
- **Status:** Implemented + verified. `mix compile --warnings-as-errors` clean; plain `mix test` **273/91**
  (Docker-free; +18 plain tests vs the prior 255, existing intact); `--include postgres_integration --include
  http_integration` **359/0**; ZERO `corr_placeholder` in production source (`.ex`). No new dependency.

- **Context:** Layers 1-2 (fast Docker-free `mix test`; pg + http_integration against a Postgres service) guard
  the in-process + adapter paths, but nothing in CI exercised the REAL multi-container network path or the
  graceful-degradation contract proven live in the compose-prod slice.
- **Decision — committed differential script:** `scripts/ci/compose_differential.sh` (`set -euo pipefail`,
  executable) drives the gateway→auth contract against a RUNNING `docker-compose.prod.yml` stack via the
  documented endpoint `GET /api/v1/auth/session` (bogus token) on the published gateway port `:4000`:
  (a) auth up → **401 `auth.session_invalid`**; (b) `docker compose stop auth` → **503 `auth.unavailable`**
  (transport-failure → 503, gateway alive, no crash); (c) `start auth` → **401** (recovery). It polls `/health`
  + each expected state with a timeout (`READY_TIMEOUT=90`), prints PASS/FAIL + body, exits non-zero on
  mismatch. Version-controlled (runnable by CI and humans) rather than fragile inline YAML; the caller owns
  stack up/down.
- **Decision — gated `compose-integration` job** in
  [.github/workflows/backend-ci.yml](../../.github/workflows/backend-ci.yml): runs ONLY on `workflow_dispatch`,
  the nightly `schedule` (cron `0 4 * * *`), or a PR labelled `ci:compose` (the `if:` guard). NOT on the
  per-push fast path — the cold build of 6 images is minutes of wall-clock and must not slow normal feedback.
  `timeout-minutes: 30` (fail-fast on a hung build); `up -d --build --wait` → run the script → `if: always()`
  `down -v` teardown. Dummy non-placeholder secrets via job `env:` satisfy the prod guard (compose interpolates
  them). The `backend` and `integration` jobs are byte-unchanged.
- **Status:** Implemented + verified LOCALLY end-to-end: built 6 images, `up --wait`, the script PASSED all 3
  states (401 / 503 / 401), torn down with `-v`; fast gate `mix test` **255/89** unchanged (Docker-free). The
  gated job won't auto-run on push (by design) — proven on CI via manual `workflow_dispatch`.

## [2026-06-24] `:req` not started → Finch pool `:noproc` (CI-proven follow-up to the `:httpc`→Req swap)

- **What:** after swapping to Req, internal HTTP calls in CI's per-app test boot hit
  `{:noproc, {GenServer, :call, [Req.FinchSupervisor, ...]}}` — the `:req` application wasn't started, so
  Req's default Finch pool supervisor (`Req.FinchSupervisor`) was absent and the lazy pool `start_child`
  exited; the adapter's `catch` then mapped it to `{:error, :*_unavailable}`. Fixed with BOTH layers:
  (a) `:req` added to `shared_infra` `extra_applications`
  ([shared_infra/mix.exs:25](../../apps/backend/apps/shared_infra/mix.exs#L25)) so it starts with the app;
  (b) `Application.ensure_all_started(:req)` on the request path —
  `ensure_req_started/0` ([http_client.ex:87-88](../../apps/backend/apps/shared_infra/lib/shared_infra/http_client.ex#L87))
  called at the top of `do_request/6` before `Req.request`
  ([http_client.ex:48](../../apps/backend/apps/shared_infra/lib/shared_infra/http_client.ex#L48)).
- **Why it passed locally but failed in CI:** the local **warm umbrella** boot happened to start `:req`; CI's
  **clean per-app** boot did not. Proven by CI run a76bdf1 (integration job): the inets/`:http_util` error was
  fully GONE (Req transport works on the OTP-27.3 runner), replaced by the Finch-pool `:noproc`. Reproduced
  locally only after a **cold rebuild** (`rm -rf _build deps`) — the warm boot had masked it. This is the same
  class of cross-environment boot-path gap the temporary `INETS DIAG` exposed for inets.
- **Latent prod impact:** a release that didn't start `:req` would have 503'd EVERY internal service→service
  call — surfaced by the integration job, not by the warm local suite. Layer (a) covers normal app/release boot;
  layer (b) is the bulletproof request-path backstop.
- **Contract unchanged:** `ensure_all_started(:req)` is idempotent (no-op where already started); all
  transport/decode/failure-mapping behavior identical (timeouts, `decode_body: false`, `decode_result/2` +
  `skip_atomize`, `{:error, :*_unavailable}` mapping untouched).
- **Status:** Implemented + verified on a COLD rebuild (`rm -rf _build deps` → `mix deps.get`): `mix compile
  --warnings-as-errors` clean; plain `mix test` **255/89** unchanged (Docker-free); `mix test --include
  postgres_integration --include http_integration` → **339/0** with ZERO `:noproc`/`FinchSupervisor` warnings.
  Real proof remains the CI `integration` job going green on push.

## [2026-06-24] HttpClient transport — swap OTP `:httpc` → Req (CI-proven inets fragility)

- **What:** the internal service→service HTTP transport in `SharedInfra.HttpClient` changed from OTP `:httpc`
  to **Req** (Finch/Mint) — one isolated module
  ([http_client.ex:48](../../apps/backend/apps/shared_infra/lib/shared_infra/http_client.ex#L48), `Req.request(...)`)
  + a new dep `{:req, "~> 0.5"}` ([shared_infra/mix.exs:35](../../apps/backend/apps/shared_infra/mix.exs#L35),
  resolved to req 0.6.2 + finch/mint/nimble_pool/hpax/nimble_options in mix.lock). `:inets` dropped from
  `shared_infra` `extra_applications`; `:ssl` retained for TLS
  ([shared_infra/mix.exs:23](../../apps/backend/apps/shared_infra/mix.exs#L23)).
- **Why (real, CI-proven):** the GitHub runner's OTP 27.3.x build had `:http_util` as `:non_existing` — proven by
  a temporary `INETS DIAG` line on the CI `integration` job: `otp=27 inets_vsn=9.3.2.6 http_util_which=:non_existing`.
  `:httpc.request` internally calls `:http_util.timestamp/0`, which raised `UndefinedFunctionError` on EVERY
  `http_integration` round-trip (the adapter's rescue then masked it as `{:error, :*_unavailable}`). This is a
  known `:httpc`/inets environment fragility (seen across inets 8.x/9.x), NOT an app bug. Local (OTP 29, inets
  9.7.1) and the prod Docker image both have a working `:httpc`, so only the CI runner's build was affected — which
  is why http_integration passed locally across all prior attempts.
- **What was tried first (so nobody re-treads):** (a) `Application.ensure_all_started(:inets)` in `do_request` —
  insufficient: the module was genuinely ABSENT from the runner's code path (`:non_existing`), not merely
  unstarted. (b) Bumping CI OTP/Elixir (tried OTP 29.0 / `1.18.4-otp-29`) — rejected: the latest 27.x already
  ships the broken inets, and a `1.18.4-otp-29` precompiled build's availability in `setup-beam` was an unresolved
  risk (Elixir 1.18 predates OTP 29). Req was chosen instead: version-independent, carries its own pure-Elixir
  transport, removes the inets dependency for CI/local/prod alike, and was already the project's planned direction.
- **Contract preserved (zero behavior change):** same headers incl. `x-internal-token`
  ([:91](../../apps/backend/apps/shared_infra/lib/shared_infra/http_client.ex#L91)); POST `content-type:
  application/json` with a `Jason`-encoded body
  ([:36-37](../../apps/backend/apps/shared_infra/lib/shared_infra/http_client.ex#L36)); `decode_body: false`
  ([:53](../../apps/backend/apps/shared_infra/lib/shared_infra/http_client.ex#L53)) so JSON parsing stays ours
  (`decode/3` → `SharedInfra.InternalApi.decode_result/2`,
  [:79-86](../../apps/backend/apps/shared_infra/lib/shared_infra/http_client.ex#L79)) — atom-key rehydration +
  `skip_atomize: ["metadata"]` ([message_client_http.ex:19](../../apps/backend/apps/shared_infra/lib/shared_infra/message_client_http.ex#L19))
  unchanged; same connect/receive timeouts ([:55-56](../../apps/backend/apps/shared_infra/lib/shared_infra/http_client.ex#L55),
  `retry: false`); same `{:error, :*_unavailable}` mapping for non-200 / transport-failure / raise / throw
  ([:62-76](../../apps/backend/apps/shared_infra/lib/shared_infra/http_client.ex#L62)).
- **Status:** Implemented + verified locally. `mix compile --warnings-as-errors` clean; plain `mix test`
  **255/89** unchanged (Docker-free; default path never touches the transport); `mix test --include
  postgres_integration --include http_integration` → **339/0**. CI version bump fully reverted (jobs stay on OTP
  27.3 / Elixir 1.18.4) — Req, not an OTP bump, is the fix. The temporary `INETS DIAG` probe is removed. THE REAL
  PROOF is the CI `integration` job going green on push — exactly the value Layer 2 delivered (it surfaced a real
  cross-environment transport bug the in-process suite never could).

## [2026-06-23] HttpClient — ensure `:inets` started before `:httpc` (CI-surfaced latent prod bug)

- **Context:** the new `integration` job's first run failed every `http_integration` round-trip across all 5
  adapters with `[warning] internal HTTP call raised: %UndefinedFunctionError{module: :http_util, function:
  :timestamp, arity: 0}` → adapter returned `{:error, :*_unavailable}`. `:http_util.timestamp/0` is part of
  OTP's `:inets`; on a fresh CI runner `:inets` wasn't started, so `:httpc.request` raised and the rescue in
  [http_client.ex:57](../../apps/backend/apps/shared_infra/lib/shared_infra/http_client.ex#L57) converted it into
  a spurious unavailable. Locally `:inets` happened to already be running, so it passed — exactly the gap CI
  exists to catch. The `postgres_integration` suite (323) all passed; only the `:httpc` transport was affected.
- **Root cause:** single + environmental, NOT a logic bug. `shared_infra` already lists `:inets`/`:ssl` in
  `extra_applications` ([mix.exs:23](../../apps/backend/apps/shared_infra/mix.exs#L23)), but that does NOT
  reliably start them across every test/release boot path — a fresh runner proved it. This is also a LATENT PROD
  bug: a release container would hit the same unstarted-`:inets` raise → so fix it in code, not just CI.
- **Decision:** `SharedInfra.HttpClient.do_request/4` now calls a tiny `ensure_inets_started/0`
  (`Application.ensure_all_started(:inets)` + `:ssl`) before every `:httpc` call. Idempotent (no-op once started)
  → negligible per-call cost, guarantees the transport apps are up in CI / prod release / local alike. Kept
  `extra_applications` as-is (correct, just insufficient alone). NO change to adapter logic, the result-envelope,
  or the failure mapping — genuine transport failures (dead port etc.) still map to `{:error, :*_unavailable}`.
- **Status:** Implemented + verified locally. `mix compile --warnings-as-errors` clean; plain `mix test` 255/89
  unchanged (default path doesn't touch `:httpc`); `mix test --include postgres_integration --include
  http_integration` against a Postgres service (full schema) → **339 passed, 0 failures** (323 pg + 16 adapter
  round-trips), incl. the dead-port tests still returning `:*_unavailable`. Local caveat: `:inets` was already
  running locally, so this proves NO regression — the actual unstarted-`:inets` fix is proven by the fresh CI
  runner. THE REAL PROOF: the `integration` job going green on this push. This is precisely the value of Layer 2.

## [2026-06-23] CI rework — layered CI: fast gate (unchanged) + `integration` job (pg + http_integration in CI)

- **Context:** CI only ran the fast Docker-free umbrella `mix test` (255/89, in-process path). The DB suite
  (323) and the 5 HTTP client adapters' `http_integration` round-trips ran ONLY locally → the microservices
  runtime + the wire contract were unguarded; a change could break a network/DB path and CI stay green.
- **Decision — add a SECOND job `integration`, parallel to `backend`, leaving the fast gate UNTOUCHED.** Same
  triggers/toolchain (setup-beam OTP 27.3/Elixir 1.18.4, cmake/build-essential, same deps/_build cache key) +
  a `postgres:16` SERVICE container (health-checked) creating `chat_platform_test`. Runs
  `mix test --include postgres_integration --include http_integration`. Layer 1 (fast Docker-free `mix test`,
  255/89) stays the quick signal on every push; Layer 2 locks the distributed/DB behavior without slowing it.
- **Decision — load the FULL schema, not just 010.** The job loads ALL `infra/docker/postgres/init/*.sql` in
  filename order (001..042 → 36 tables) with `ON_ERROR_STOP=1`. The 323 suite needs message-store (020),
  projections (030), notifications (040-042); loading only `010_initial_schema.sql` (as the stale
  LOCAL_DEV_SETUP.md said) would fail those tests. Fixed the doc to match (the doc + CI job now agree).
- **Decision — secrets:** Layer 2 runs in `:test` (placeholder secrets fine — no prod guard); only Layer 3
  (compose, `:prod`) will need dummy CI secrets. **Per-service test jobs deferred** (umbrella suite + the two
  integration tags already cover each service; per-service jobs add N× overhead for little signal — revisit if
  repos/release cadences diverge). **Compose/network differential = Layer 3**, a later label/nightly-gated job
  (heavy image build; must not slow PRs) — NOT in this slice.
- **Status:** Implemented. Workflow YAML validated locally (both jobs parse; `backend` `mix test` byte-unchanged;
  `integration` has the postgres service + the two `--include` tags). Fast gate locally still 255/89. CI-config
  only — no app/test code. **The real proof is the GitHub Actions run:** the `integration` job must reproduce
  the local numbers (pg 323 + the 5 adapters' http_integration green) against the service container with the
  full schema; watch the first run. Risks to watch in run #1: http_integration fixed-port binding on the shared
  runner; schema-load ordering/`ON_ERROR_STOP`. Next: Layer 3 compose differential (label/nightly).

## [2026-06-23] Microservices split — docker-compose.prod.yml (first real multi-container bring-up) — CORE SPLIT PROVEN

- **Context:** per-service images build; now run them as separate containers with the gateway calling services
  over the network — the first real cross-network proof of the split.
- **Decision — `docker-compose.prod.yml` at repo ROOT.** It spans both `apps/backend` (build context) and
  `infra/docker/postgres/init` (schema mount), so root is the natural home. 7 containers (postgres + auth +
  conversation + user + message + media + gateway) on a shared bridge `chatnet`; services reachable by name
  (`http://auth:4101` …). Ports = code defaults (auth 4101, conversation 4102, user 4103, message 4104, media
  4105, gateway 4000). YAML anchors (`x-secrets`, `x-service-base`) keep per-service env DRY. Service ports are
  internal (`expose`); only the gateway publishes `4000:4000`.
- **Decision — gateway flipped to HTTP.** Gateway env sets all 5 `*_CLIENT_ADAPTER=http` + `*_SERVICE_URL`; each
  service sets its `*_HTTP_API_ENABLED=true` + `*_HTTP_PORT` + `*_DB_BACKED` (+ message `MESSAGE_STORE_ADAPTER=
  postgres`). All five services share ONE Postgres for the first deploy (per runtime.exs).
- **Decision — schema via initdb.** Mount `infra/docker/postgres/init` (001..042, ordered) into the postgres
  container's `/docker-entrypoint-initdb.d`; Postgres auto-runs `*.sql` in filename order on FIRST init of an
  empty volume → full schema before any service connects (the natural compose fit; no migration runner needed).
- **Decision — staged rollout, Kafka/Redis/Scylla/MinIO OFF.** Core chat first; their flags stay off. Can be
  added later (dev infra compose has them). Consequence: full media object storage (MinIO) and the event
  consumers are deferred; media container still boots + the gateway's media routes resolve.
- **Decision — startup ordering + 503 fallback.** Services wait for postgres' healthcheck; the gateway waits only
  for services to START (slim images have no curl for a readiness probe). A gateway call to a not-yet-listening
  service returns `:*_unavailable`→503, NOT a crash — the client-adapter failure semantics pay off here.
- **Secrets:** one shared `INTERNAL_API_TOKEN` + `SECRET_KEY_BASE`/`TOKEN_SECRET`/`OTP_SECRET` from a repo-root
  `.env` (compose auto-loads; `.env.prod.example` template committed, `.env` gitignored — added
  `!.env.prod.example` exception). Never baked into images.
- **Status:** Implemented + PROVEN LIVE (Docker available). `docker compose config` valid; all 6 service images
  build; `up -d` → all 7 containers running; `GET /health` → 200; schema = 36 tables auto-applied. **Cross-network
  proof:** `GET /api/v1/auth/session` (bogus token) → 401 `auth.session_invalid` (gateway→auth over HTTP); STOP
  auth → same call → **503 `auth.unavailable`** (transport-failure fallback); RESTART auth → 401 again
  (auto-recovery, no gateway crash). Compose + docs only — plain `mix test` 255/89 unchanged; web untouched
  (separate deploy; `NEXT_PUBLIC_API_BASE_URL=http://localhost:4000`). **The microservices split is now proven
  end-to-end across containers.** Next: optional DB-per-service + CI rework; re-enable Kafka/MinIO when staged.

## [2026-06-23] Microservices split — per-service Docker images via ONE parameterized Dockerfile

- **Context:** the per-service releases assemble; now each needs a container image bundling one release. Choice:
  (a) one parameterized Dockerfile with a `RELEASE` build-arg, or (b) one Dockerfile per service.
- **Decision: (a) — one parameterized Dockerfile.** The release name is the ONLY thing that varies (build
  context = `apps/backend`, identical build/runtime stages, identical secret guard); six near-identical files
  would be pure duplication + drift risk. `ARG RELEASE=chat_platform` (re-declared per stage); build stage
  `mix release "$RELEASE"` then `cp` to a fixed `/release` path so the runtime stage is release-agnostic;
  `ENV RELEASE_BIN=$RELEASE` + `CMD ["/bin/sh","-c","exec /app/bin/$RELEASE_BIN start"]` (exec → release is
  PID 1 so SIGTERM reaches the VM; shell form needed because ARG isn't readable at container runtime). `ARG
  SERVICE_PORT` drives `EXPOSE` (metadata only).
- **Decision: folded the single-container Dockerfile INTO the parameterized one.** Default `RELEASE=chat_platform`
  → `docker build apps/backend` with no build-arg reproduces the original all-in-one image (3b baseline
  unchanged). One Dockerfile, no duplication.
- **Note (no code change):** the shared `config/runtime.exs` makes EVERY release require the full prod env in
  `:prod` (incl. `PHX_HOST`, a gateway concern) — documented in DEPLOYMENT.md; per-release guard refinement is a
  later option, out of scope here.
- **Status:** Implemented + verified WITH Docker (available this session). Built `chat/auth_service` +
  `chat/gateway` for real → both succeed, ≈259 MB each. auth image NO secrets → fail-fast (`DATABASE_URL`/`PHX_HOST`
  guard, proving nothing baked + the per-service release boots far enough to enforce it); auth image with dummy
  secrets + `AUTH_HTTP_API_ENABLED=true` → boots and the Plug listener answers on 4101 (`curl` → HTTP 401 from
  `TokenPlug`, fail-closed), Postgres retried in background without crashing boot. Build/config only — plain
  `mix test` 255/89 unchanged (Dockerfile adds no app code; not on the Elixir compile/test path). `.dockerignore`
  unchanged (still suits per-service builds). Next: `docker-compose.prod.yml` — first real multi-container bring-up.

## [2026-06-23] Microservices split — per-service releases + edge dep cleanup (mechanism iii; NO shared_infra package)

- **Context:** to ship each service as its own container we need release packaging that bundles one service at
  a time. Phase-1 inspection found shared_infra has ZERO compile-time coupling to any service (only runtime
  default-adapter atoms + doc comments) and the edge apps (api_gateway, realtime_gateway) had ZERO residual
  `*Service.*` code references (all calls go via `SharedInfra.*Client`).
- **Decision — mechanism (iii): no shared_infra package extraction.** shared_infra stays `{:in_umbrella}`;
  per-service `mix release` definitions from the monorepo bundle each app. Rejected separate-repo (i) — a
  2-repo edit→tag→bump workflow is needless friction given zero compile-coupling; rejected dual path-dep (ii)
  as redundant with in_umbrella. Lowest dev friction; plain `mix test` stays Docker-free + unchanged.
- **Decision — the REAL decoupling: drop unused edge→service in_umbrella deps.** Removed
  `{:auth/:conversation/:user/:message/:media_service, in_umbrella}` from `api_gateway/mix.exs` and
  `{:auth/:conversation/:message_service, in_umbrella}` from `realtime_gateway/mix.exs` (kept
  `{:shared_infra, in_umbrella}` — needed for the `*Client` dispatchers). These deps were unused at the code
  level (verified zero refs) but would have bundled all 5 services into the gateway image. This is what makes
  the gateway release lean.
- **Decision — per-service releases in `apps/backend/mix.exs`:** `auth_service`, `user_service`,
  `conversation_service`, `message_service`, `media_service` (each `[<svc>, shared_infra]`), plus `gateway`
  (`[api_gateway, realtime_gateway, shared_infra]`). Kept the all-in-one `chat_platform` release for the
  single-container baseline. (notification_service has no per-service release yet — add when it's containerized.)
- **Status:** Implemented + verified. Packaging-only — ZERO runtime behavior change. `mix compile
  --warnings-as-errors` clean AFTER the dep-drop; plain `mix test` 255/89 UNCHANGED (in-process adapters still
  resolve — the dep governed compile-order/bundling, not runtime resolution → no hidden assumption); pg 323
  unchanged. All 7 releases assemble under `MIX_ENV=prod mix release` (runtime.exs secrets guard runs at boot,
  not assembly). Bundling confirmed lean: `gateway/lib` = api_gateway + realtime_gateway + shared_infra only
  (no service apps); `auth_service/lib` = auth_service + shared_infra only. Next: per-service Dockerfiles →
  docker-compose.prod → optional DB-per-service → CI rework.

## [2026-06-23] Microservices HTTP client adapter — Media; CLIENT-ADAPTER SET COMPLETE (all 5)

- **Context:** last of the 5 HTTP client adapters. Flip via `MEDIA_CLIENT_ADAPTER=http`; default in-process.
- **Decision:** `SharedInfra.MediaClientHttp` (in shared_infra) — `@behaviour SharedInfra.MediaClient`; 3
  callbacks → `HttpClient.post_result` with `MEDIA_SERVICE_URL` + route + `unavailable: :media_unavailable`
  (no metadata caveat). Gateway maps `:media_unavailable`→503 at every media_controller site (after the
  existing `:auth_unavailable`). Placeholder paths (persistence off) keep their `_ -> invalid_request`
  catch-all (no crash; misconfig if http-adapter + persistence-off). Additive; dead in the default path.
- **MILESTONE — client-adapter set COMPLETE:** all 5 `SharedInfra.*Client` dispatchers (Auth, Conversation,
  User, Message, Media) now have HTTP adapters selectable by a per-service `*_CLIENT_ADAPTER=http` flag +
  `*_SERVICE_URL`, each with transport-failure → `{:error, :*_unavailable}` → gateway 503 / realtime reject,
  and proven shape-identical round-trips (incl. atom-keyed maps + message `metadata` string-keyed). Defaults
  all in-process → the umbrella behaves identically until a flag is flipped.
- **Status:** Implemented + verified. plain `mix test` 254→255 (+1 plain 503-mapping test; existing 254 INTACT);
  pg 322→323; `mix test --include http_integration` → all 5 adapters pass (media 3 + message 4 + user 3 +
  conversation 3 + auth 3; round-trips == in-process, dead port → `:*_unavailable`). Default in-process; no
  listener at boot. Next phase: shared_infra extraction → per-service releases/Dockerfiles → docker-compose.prod
  → optional DB-per-service → CI rework.

## [2026-06-23] Microservices HTTP client adapter — Message + the metadata caveat (decoder skip option)

- **Context:** fourth HTTP client adapter (the heaviest, 9 callbacks) — and the one carrying the documented
  `metadata` fidelity caveat. Flip via `MESSAGE_CLIENT_ADAPTER=http`; default in-process → zero behavior change.
- **Decision — metadata caveat resolved via option (i):** `SharedInfra.InternalApi.decode_result/2` gained
  `opts[:skip_atomize]` — a list of string keys whose VALUE is left verbatim (NOT recursed/atomized) at ANY
  depth. `SharedInfra.MessageClientHttp` decodes every call with `skip_atomize: ["metadata"]`, so a message's
  FREE-FORM, user-provided `metadata` stays string-keyed (matching in-process) and arbitrary atoms are never
  minted from user input (atom-table exhaustion). Chose (i) over per-adapter post-processing because it's
  generic + the default `[]` leaves the other 3 adapters' behavior provably unchanged (their callers don't pass
  it). Threaded through `HttpClient.post_result(..., decode: [...])`.
- **Decision — `SharedInfra.MessageClientHttp`:** 9 callbacks → `HttpClient.post_result` with
  `MESSAGE_SERVICE_URL` + route + `unavailable: :message_unavailable` + `decode: [skip_atomize: ["metadata"]]`.
  `list_timeline` → `/internal/timeline/list`.
- **Decision — gateway + realtime 503 mapping (additive):** `{:error, :message_unavailable}` → 503 at every
  message_controller MessageClient site (after the existing `:auth_unavailable`); realtime `conversation_channel`
  create/update/delete → `realtime.unavailable` (new `unavailable_reply/1`). Dead in the default path.
- **Status:** Implemented + verified. plain `mix test` 249→254 (+5 plain: 3 `decode_result` skip-atomize proofs
  [metadata string-keyed at top level + nested in lists; default fully-atomizes] + gateway 503 + realtime
  unavailable; existing 249 INTACT); pg 317→322; `mix test --include http_integration` → message 4 + user 3 +
  conversation 3 + auth 3 passed (round-trips == in-process; dead port → `:message_unavailable`). Default
  in-process. Next: Media HTTP adapter (last) → then shared_infra extraction, releases/Docker, compose.

## [2026-06-23] Microservices HTTP client adapter — User (copies the pattern)

- **Context:** third HTTP client adapter. Flip via `USER_CLIENT_ADAPTER=http`; default in-process → zero
  behavior change.
- **Decision:** `SharedInfra.UserClientHttp` (in shared_infra) — `@behaviour SharedInfra.UserClient`; 3
  callbacks → `HttpClient.post_result` with `USER_SERVICE_URL` + route + `unavailable: :user_unavailable`.
  Atom-keyed profile maps round-trip via `decode_result`.
- **Decision — gateway 503 mapping, fixing a no-catch-all hazard:** added `{:error, :user_unavailable}` → 503
  at every `UserClient` call-site. The public **`profile/2`** action (NOT persistence-gated — always calls
  `get_public_profile`) had only a `:profile_invalid` clause and NO catch-all → `:user_unavailable` would have
  crashed it (500); added the clause. The two persistence paths got the clause after their existing
  `:auth_unavailable`. Placeholder paths (persistence off) left unhandled + documented (HTTP-adapter implies
  persistence on). Existing clauses untouched; dead in the default path.
- **Status:** Implemented + verified. plain `mix test` 248→249 (+1 plain 503-mapping test; existing 248 INTACT);
  pg 316→317; `mix test --include http_integration` → user 3 passed (round-trip == in-process incl. atom-keyed
  profile; dead port → `:user_unavailable`) + conversation 3 + auth 3 (regression). Default in-process; no
  listener at boot. Next: message (don't atomize `metadata`) + media HTTP adapters.

## [2026-06-23] Microservices HTTP client adapter — Conversation (copies the Auth pattern)

- **Context:** second HTTP client adapter, copying the Auth template (`SharedInfra.HttpClient` +
  `decode_result`). Flip via `CONVERSATION_CLIENT_ADAPTER=http`; default in-process → zero behavior change.
- **Decision:** `SharedInfra.ConversationClientHttp` (in shared_infra) — `@behaviour SharedInfra.ConversationClient`;
  5 callbacks → `HttpClient.post_result` with `CONVERSATION_SERVICE_URL` + route + `unavailable: :conversation_unavailable`.
  Atom-keyed conversation/participant maps + nested participant lists round-trip via the recursive `decode_result`.
- **Decision — gateway/realtime 503 mapping (additive, every call-site):** `{:error, :conversation_unavailable}`
  → 503 added at every `ConversationClient` site: conversation_controller (all actions, after the existing
  `:auth_unavailable` clause), message_controller membership gate (`authorize_membership` now PROPAGATES
  `:conversation_unavailable` instead of collapsing it to `:conversation_membership_forbidden`/403, and the
  two membership-gated actions map it to 503), and realtime `topic_authorization` (new clause →
  `realtime.unavailable`, instead of falling through to the `rescue` internal_error). Existing atom clauses
  untouched; `:conversation_unavailable` only arises when the adapter is flipped (default in-process) → dead
  in the default path → zero behavior change.
- **Note (latent, documented):** the conversation_controller PLACEHOLDER paths (persistence OFF) have no else
  and would crash on `:conversation_unavailable` — but flipping to the HTTP adapter implies the real path
  (persistence on); HTTP-adapter + persistence-off is a misconfiguration, not handled.
- **Status:** Implemented + verified. plain `mix test` 246→248 (+2 plain 503-mapping tests — gateway + realtime;
  existing 246 INTACT); pg 314→316; `mix test --include http_integration` → conversation 3 passed (round-trip ==
  in-process incl. atom-keyed/nested; dead port → `:conversation_unavailable`) + auth 3 passed (regression).
  Default in-process; no listener at boot. Next: user/message/media HTTP adapters (Message: don't atomize `metadata`).

## [2026-06-23] Microservices HTTP client adapter — Auth (first; traffic can flip to network)

- **Context:** internal HTTP APIs exist (server side, all 5). This builds the FIRST HTTP CLIENT adapter so
  `AUTH_CLIENT_ADAPTER=http` makes the gateway call auth-service over the network. Default stays in-process
  (zero behavior change). Sets the adapter + failure-handling template the other 4 copy.
- **Decision — HTTP lib = `:httpc`, NOT Req (environment-forced):** the plan chose Req for ergonomic
  timeouts/error tuples, but `mix deps.get` **failed — the package registry (`repo.hex.pm`) is unreachable
  in this environment and Req isn't cached**, so Req is un-installable here. Pivoted to OTP's `:httpc`
  (`:inets`/`:ssl` added to shared_infra `extra_applications`) — zero new deps, capable of connect/receive
  timeouts. **Isolated entirely in `SharedInfra.HttpClient`** so Req can be swapped in later by changing one
  module once a registry is reachable. (Reported, not silently substituted.)
- **Decision — `SharedInfra.HttpClient` shared helper:** `post_result/4`/`get_result/3` build request
  (base URL + path + `x-internal-token` + JSON), apply 2s connect / 5s receive timeouts; HTTP 200 →
  `InternalApi.decode_result/1` (shape-identical to in-process incl. atom-keyed maps + preserved domain
  error atoms); any transport failure (connect refused / timeout / non-200 / non-JSON) → `{:error,
  unavailable_atom}`. All 5 adapters reuse it → uniform failure/timeout/token handling.
- **Decision — `SharedInfra.AuthClientHttp` lives in shared_infra** (not auth_service — the gateway won't
  include auth_service post-split). `@behaviour SharedInfra.AuthClient`; transport failure → `:auth_unavailable`;
  `persistence_enabled?` fails CLOSED (`false`) on failure (never a truthy tuple → realtime socket stays safe).
- **Decision — gateway failure semantics (NEW, additive):** added `ErrorResponse.service_unavailable/2` (503)
  + `{:error, :auth_unavailable} -> service_unavailable(conn)` at EVERY `current_session` call-site (auth/user/
  message/conversation/media) and the auth otp/refresh/logout actions. `session/2` had no catch-all (would have
  500'd); the others would have wrongly 400'd. `:auth_unavailable` only arises when the adapter is flipped on
  (default in-process), so these clauses are dead in the default path → zero behavior change. Realtime socket
  already fails closed on any auth error (no change).
- **Status:** Implemented + verified. plain `mix test` 244→246 (existing 244 INTACT + 2 plain 503-mapping tests;
  +3 excluded `:http_integration`); pg 312→314; `mix test --include http_integration` → **3 passed** (real
  localhost round-trip == in-process; transport failure → `:auth_unavailable`). Default selection in-process;
  no listener at boot. Next: conversation/user/message/media HTTP adapters (Message: don't atomize `metadata`).

## [2026-06-18] Microservices internal HTTP API — Media service; INTERNAL-API SET COMPLETE (all 5)

- **Context:** last of the internal-API set (Auth/Conversation/User/Message done). media_service is the
  simplest (no Repo, 3 routes).
- **Decision:** `MediaService.HTTP.Router` (Plug) — routes 1:1 with `SharedInfra.MediaClient`
  (create_upload, complete_upload, get_download_url) → `MediaService.Media` → `encode_result`. Atom-keyed
  upload/download maps; `:media_invalid` preserved. Listener `Plug.Cowboy` gated `MEDIA_HTTP_API_ENABLED`
  (+ `MEDIA_HTTP_PORT`, default 4105), default off — the listener is media_service's ONLY supervised child
  (no Repo). media_service +plug/plug_cowboy/jason.
- **MILESTONE — internal-API set COMPLETE:** all 5 services (Auth/Conversation/User/Message/Media) now have
  internal HTTP APIs (Plug routers reusing `SharedInfra.InternalApi` + `TokenPlug`), each gated default-off.
  The wire contract (result-envelope + error-atom preservation + key rehydration) is uniform and documented
  in INTERNAL_API.md. Nothing calls them yet — the in-process `SharedInfra.*Client` adapters remain default.
- **Status:** Implemented + verified, zero behavior change. plain `mix test` 240→244 (existing 240 INTACT +
  4 plain tests, incl. the FIRST router-level error-atom round-trip — media's invalid path deterministically
  returns `:media_invalid`; `MediaService.Supervisor` children `== []` in test → no listener at boot); pg 308→312.
  Next phase: HTTP client adapters (`*ClientHttp`) flip `SharedInfra.*Client` to network behind a flag.

## [2026-06-18] Microservices internal HTTP API — Message service (heaviest, 9 routes)

- **Context:** fourth internal HTTP API (Auth/Conversation/User done); MessageService is the heaviest (9
  functions across Messages/Timeline/Receipts). Same template.
- **Decision:** `MessageService.HTTP.Router` (Plug) — 9 routes 1:1 with `SharedInfra.MessageClient`
  (create/send/list/update/edit/delete_message, `list_timeline`→`Timeline.list_messages`, mark_read/
  mark_delivered) → `MessageService.{Messages,Timeline,Receipts}` → `encode_result`. Error atoms
  `:message_invalid`/`:message_forbidden` preserved. Listener gated `MESSAGE_HTTP_API_ENABLED`
  (+ `MESSAGE_HTTP_PORT`, default 4104), default off. message_service +plug/plug_cowboy.
- **Decision — documented metadata fidelity caveat:** a message's `metadata` is a FREE-FORM, string-keyed
  map; the generic `decode_result` atomizes keys, which would corrupt it. The future Message HTTP client
  adapter MUST preserve `metadata`'s string keys (skip atomizing that sub-map). Placeholder paths carry no
  metadata, so plain round-trips are clean; the caveat bites only the DB path. Documented in INTERNAL_API.md.
- **Status:** Implemented + verified, zero behavior change. plain `mix test` 235→240 (existing 235 INTACT +
  5 plain Plug.Test tests covering Messages/Timeline/Receipts + the list_timeline distinction + TokenPlug;
  `MessageService.Supervisor` children `== []` in test → no listener at boot); pg 303→308. Only **Media**
  internal API remains, then the HTTP client adapters.

## [2026-06-18] Microservices internal HTTP API — User service (copies the template)

- **Context:** third internal HTTP API (Auth, Conversation done), copying the same template.
- **Decision:** `UserService.HTTP.Router` (Plug) — routes 1:1 with `SharedInfra.UserClient`
  (get_current_profile, get_public_profile, update_current_profile) → `UserService.Profiles` →
  `encode_result`. Atom-keyed profile maps (`user_id, display_name, avatar_media_id, bio`) round-trip
  via the shared envelope; `:profile_invalid` preserved. Listener `Plug.Cowboy` gated
  `USER_HTTP_API_ENABLED` (+ `USER_HTTP_PORT`, default 4103), default off. user_service +plug/plug_cowboy/jason.
- **Status:** Implemented + verified, zero behavior change. plain `mix test` 231→235 (existing 231 INTACT +
  4 plain Plug.Test tests; `UserService.Supervisor` children `== []` in test → no listener at boot);
  pg 299→303. Next: message/media internal APIs, then the HTTP client adapters.

## [2026-06-18] Microservices internal HTTP API — Conversation service (copies the Auth template)

- **Context:** second internal HTTP API, copying the Auth template (`SharedInfra.InternalApi` + `TokenPlug`
  + a Plug router + gated `Plug.Cowboy` child). Server side only; nothing calls it yet → zero behavior change.
- **Decision:** `ConversationService.HTTP.Router` (Plug) with routes 1:1 to `SharedInfra.ConversationClient`
  (create/list/get_conversation, add/remove_participant), each delegating to
  `ConversationService.{Conversations,Participants}` and serializing via `SharedInfra.InternalApi.encode_result`.
  Conversation/participant responses are atom-keyed maps (nested lists of participant maps); the shared
  `decode_result` rehydrates them recursively. Error atoms preserved (`:conversation_forbidden`,
  `:participant_invalid`, etc.). Key sets + error atoms documented in INTERNAL_API.md.
- **Decision — listener gated off:** `Plug.Cowboy` child under `CONVERSATION_HTTP_API_ENABLED`
  (+ `CONVERSATION_HTTP_PORT`, default 4102), default off. Verified `ConversationService.Supervisor`
  children `== []` in test env.
- **Status:** Implemented + verified, zero behavior change. plain `mix test` 227→231 (+4 plain Plug.Test tests;
  existing 227 INTACT); pg 295→299. Next: user/message/media internal APIs, then the HTTP client adapters.

## [2026-06-18] Microservices split — internal HTTP API phase: Auth template (server side, gated)

- **Context:** with the 5 edge→service seams routed through `SharedInfra.*Client`, each service now
  needs an internal HTTP API so the future HTTP client adapters can call over the network. The 5
  services had no HTTP surface. Auth built first as the template; the other 4 copy it. Nothing calls it
  yet (in-process adapters stay default) → zero behavior change.
- **Decision — two envelopes, never conflated:** the PUBLIC user-facing envelope
  (`ApiGatewayWeb.ErrorResponse`) is gateway-only and untouched. A NEW INTERNAL result-envelope
  (`SharedInfra.InternalApi`) round-trips the in-process result: `{:ok, map}` ⇄ `{"ok": map}`,
  `{:error, atom}` ⇄ `{"error": "atom_name"}`, bare value ⇄ `{"result": value}`. **Error atoms are
  preserved** because the gateway pattern-matches on them; collapsing to codes would break it.
- **Decision — serialization fidelity / atom-key rehydration:** `decode_result/1` rehydrates JSON
  string keys back to atoms via `String.to_existing_atom/1` (atoms exist in loaded service code),
  recursively, with a string fallback. The `current_session` atom-keyed map (gateway reads
  `session.user_id`) has a documented key set (`user_id, session_id, device_id, platform, issued_at,
  expires_at`) in docs/09-devops/INTERNAL_API.md so the client adapter rehydrates unambiguously.
  All internal responses are HTTP 200 (ok/error is a domain result in the body, not transport status).
- **Decision — Plug, not Phoenix:** internal APIs are a few JSON routes → `Plug.Router` + `Plug.Cowboy`
  (lighter than a Phoenix.Endpoint). `AuthService.HTTP.Router` maps routes 1:1 to `SharedInfra.AuthClient`'s
  contract.
- **Decision — listener gated off (Docker-free preserved):** the `Plug.Cowboy` child starts ONLY under
  `AUTH_HTTP_API_ENABLED` (+ `AUTH_HTTP_PORT`, default 4101), default off. Verified: `AuthService.Supervisor`
  children `== []` in test env → no listener at boot, plain `mix test` unaffected.
- **Decision — internal service-to-service auth = NEW security surface:** `SharedInfra.InternalApi.TokenPlug`
  requires `x-internal-token` == `INTERNAL_API_TOKEN` (constant-time), **fails closed** if unset; intended
  to run on a private network. Flagged prominently as a new attack surface.
- **Status:** Implemented + verified, zero behavior change (nothing calls the API; in-process default holds).
  plain `mix test` 215→227 (+12 plain Plug.Test/round-trip/token tests; existing 215 INTACT); pg 283→295.
  Next: copy the template to conversation/user/message/media, THEN the HTTP client adapters flip traffic.

## [2026-06-18] Microservices split sub-slice 5 — Media service-client boundary; client-boundary set COMPLETE

- **Context:** last of the client-boundary set (Auth/Conversation/User/Message done). MediaService is the
  simplest seam — only api_gateway/media_controller, and media_service has no Repo (storage-adapter based).
- **Decision:** `SharedInfra.MediaClient` (behaviour + dispatcher, adapter from `:shared_infra, :media_client_adapter`)
  + `MediaService.MediaClientInProcess` (default, delegates to `MediaService.Media` with identical shapes).
  Functions: create_upload, complete_upload, get_download_url. media_controller now calls
  `SharedInfra.MediaClient.*`; no `MediaService.Media.*` calls remain in edge code (grep-confirmed).
  media_service now deps shared_infra (no cycle). Future `MEDIA_CLIENT_ADAPTER=http` drops in unchanged.
- **MILESTONE — client-boundary set COMPLETE:** all five edge→service seams (Auth, Conversation, User,
  Message, Media) now route through `SharedInfra.*Client` dispatchers with in-process default adapters.
  No edge app (api_gateway, realtime_gateway) calls any `*Service.*` domain module directly anymore. The
  edge↔service interface is now a single swappable layer — each service's HTTP adapter + container split
  can land independently without touching call sites.
- **Status:** Implemented + verified, zero behavior change. plain `mix test` 211→215 (existing 211 INTACT +
  4 delegation tests); pg 279→283. Sub-slice 5 of ~12-18. Next phase: internal HTTP API per service +
  HTTP client adapters, then shared_infra extraction, per-service releases/Docker, optional DB-per-service,
  compose + container run.

## [2026-06-18] Microservices split sub-slice 4 — Message service-client boundary (in-process, heaviest seam)

- **Context:** repeat the proven seam for MessageService — the heaviest (15 call-sites across BOTH edges:
  api_gateway/message_controller + realtime_gateway/conversation_channel).
- **Decision:** `SharedInfra.MessageClient` (behaviour + dispatcher, adapter from `:shared_infra, :message_client_adapter`)
  + `MessageService.MessageClientInProcess` (default, delegates to `MessageService.{Messages,Timeline,Receipts}`
  with identical shapes). 9 functions: create/send/list/update/edit/delete_message (Messages), `list_timeline`
  (→ `Timeline.list_messages`, named distinctly to avoid colliding with `Messages.list_messages`), mark_read/
  mark_delivered (Receipts). Edge apps now call `SharedInfra.MessageClient.*`; no `MessageService.{Messages,
  Timeline,Receipts}.*` calls remain in edge code (grep-confirmed). The conversation membership authz on the
  create/edit/delete path still goes through `SharedInfra.ConversationClient` (sub-slice 2) — left as-is.
- **Status:** Implemented + verified, zero behavior change. plain `mix test` 207→211 (existing 207 INTACT +
  4 delegation tests; the realtime channel + message tests all pass unchanged); pg 275→279. message_service
  already depended on shared_infra (no mix.exs change). Sub-slice 4 of ~12-18 — only Media left for the
  client-boundary set, then internal HTTP APIs + HTTP adapters.

## [2026-06-18] Microservices split sub-slice 3 — User service-client boundary (in-process)

- **Context:** repeat the proven Auth/Conversation seam for UserService.
- **Decision:** `SharedInfra.UserClient` (behaviour + dispatcher, adapter from `:shared_infra, :user_client_adapter`)
  + `UserService.UserClientInProcess` (default, delegates to `UserService.Profiles` with identical shapes).
  Functions: get_current_profile, get_public_profile, update_current_profile. api_gateway/user_controller
  now calls `SharedInfra.UserClient.*`; no `UserService.*` calls remain in edge code (grep-confirmed).
  user_service now deps shared_infra (no cycle). Future `USER_CLIENT_ADAPTER=http` drops in without touching
  call sites.
- **Status:** Implemented + verified, zero behavior change. plain `mix test` 205→207 (existing 205 INTACT +
  2 delegation tests); pg 273→275. Sub-slice 3 of ~12-18. Next: Message, Media.

## [2026-06-18] Microservices split sub-slice 2 — Conversation service-client boundary (in-process)

- **Context:** repeat the proven Auth seam (sub-slice 1) for ConversationService. `get_conversation` is
  used for membership authz from BOTH api_gateway (conversation_controller + message_controller:270) and
  realtime_gateway (topic_authorization), plus the conversation/participant CRUD from the gateway.
- **Decision:** `SharedInfra.ConversationClient` (behaviour + dispatcher, adapter from
  `:shared_infra, :conversation_client_adapter`) + `ConversationService.ConversationClientInProcess`
  (default, delegates to `ConversationService.{Conversations,Participants}` with identical shapes).
  Functions: create/list/get_conversation, add/remove_participant. Edge apps now call
  `SharedInfra.ConversationClient.*`; no `ConversationService.*` calls remain in edge code (grep-confirmed).
  Same layering as Auth (behaviour in shared_infra, adapter in the service, resolved from config at runtime).
- **Status:** Implemented + verified, zero behavior change. plain `mix test` 203→205 (existing 203 INTACT +
  2 delegation tests); pg 271→273. Sub-slice 2 of ~12-18. (conversation_service already depended on
  shared_infra from the producer slice — no mix.exs change needed.) Next: User/Message/Media repeat it.

## [2026-06-18] Microservices split BEGINS — service-client boundary pattern (sub-slice 1: Auth, in-process)

- **Context:** the firm decision is to split the umbrella into separately-deployable microservice
  containers (network comms, not in-process). Phase-1 inspection found all cross-app coupling is at the
  two EDGE apps (api_gateway, realtime_gateway); services are already event-decoupled. The migration is
  ~12-18 sub-slices; this is sub-slice 1 — the seam that de-risks the whole pattern, done for Auth first
  (its `current_session` is hit by every authed request, the highest-leverage seam).
- **Decision — service-client boundary (behaviour + swappable adapter), mirroring `Kafka.Producer`/`Scylla.Client`:**
  `SharedInfra.AuthClient` is a behaviour + dispatcher that selects its adapter from
  `:shared_infra, :auth_client_adapter`. Edge apps now call `SharedInfra.AuthClient.{current_session,
  persistence_enabled?,request_otp,verify_otp,refresh,revoke}` instead of `AuthService.*` directly.
- **Decision — ship ONLY the in-process adapter now:** `AuthService.AuthClientInProcess` (the configured
  default) delegates straight to `AuthService.Sessions/OTP/Tokens`, returning identical shapes → zero
  behavior change. The adapter-SELECTION mechanism is wired now; a future `AUTH_CLIENT_ADAPTER=http`
  adapter (separate auth-service container) drops in WITHOUT touching call sites — the point of the seam.
- **Decision — layering (where it lives):** the behaviour + dispatcher live in `shared_infra` (both edge
  apps already depend on it); the in-process adapter lives in `auth_service` (which now deps shared_infra
  — no cycle, shared_infra never deps a service). shared_infra resolves the adapter module from config at
  RUNTIME, so it stays a clean, extractable base lib (the future shared dep).
- **Decision — minimal scope:** only Auth converted; `{:auth_service, in_umbrella: true}` left in edge
  mix.exs for now (call-sites are decoupled; dep removal follows when the HTTP adapter lands). Other
  services (user/conversation/message/media) untouched — they repeat this exact pattern in later slices.
- **Status:** Implemented + verified. No edge code calls `AuthService.*` directly anymore (grep-confirmed);
  plain `mix test` 200→203 (existing 200 INTACT + 3 delegation tests; zero behavior change); pg 268→271.
  This is sub-slice 1 of ~12-18; the pattern is now established for the remaining services.

## [2026-06-18] Deploy sub-slice 3a: Fly.io config + deploy runbook (config only; deploy is the user's step)

- **Context:** the image builds and boots with a guard (sub-slices 1-2); now produce the Fly config +
  an exact runbook so the user can deploy. `flyctl` is not installed here, so this slice is config +
  docs only — no actual deploy.
- **Decision — `apps/backend/fly.toml`:** deploy from `apps/backend` (matches the Docker build context);
  `[build] dockerfile`, `[http_service] internal_port = 4000` + `force_https` + `min_machines_running = 1`
  (Fly proxies HTTP→WS upgrades over the same port, so Phoenix channels work with `wss://` and no special
  config; keeping ≥1 machine avoids dropping WS sessions on idle auto-stop). `[[vm]]` shared-cpu-1x/512MB.
  Core-chat-ON / Kafka-OFF flags in `[env]`; secrets NOT in the file.
- **Decision — schema apply = manual ordered psql (once), not a release_command:** there are no Ecto
  migrations, and the `infra/docker/postgres/init/*.sql` files are outside the release (build context is
  `apps/backend`; `infra/` is at repo root), so a `release_command` can't see them and the slim runtime
  has no psql. The runbook applies `001 → 042` via `fly proxy` + `psql` once before first boot. A bundled
  migration story is future work.
- **Decision — `check_origin` via env (`WEB_ORIGIN`), default off:** the web URL isn't known at first
  deploy, so `runtime.exs` reads `WEB_ORIGIN` (comma-separated) into `check_origin`, defaulting to `false`
  (allow-all) until set — documented as a deliberate first-deploy convenience to lock down once the web
  origin exists. (Already implemented in sub-slice 1; no code change this slice.)
- **Decision — staged rollout confirmed:** first deploy omits ALL `KAFKA_*` env ⇒ default `NoopProducer`,
  no consumers, no broker needed; Kafka is enabled later (sub-slice 6).
- **Status:** Config + runbook delivered & inspection-validated; `runtime.exs` confirmed to read every Fly
  boot value (no code change → `mix test` unchanged 200/73; 268 pg). The actual `fly deploy` + managed-PG
  TLS + schema apply + public WSS are the USER's next step and the real (unverifiable-here) proof.

## [2026-06-18] Deploy sub-slice 2: containerize (multi-stage Dockerfile for the umbrella release)

- **Context:** sub-slice 1 produced a buildable `mix release chat_platform`; this packages it into a
  deployable image without baking secrets and keeping the image small.
- **Decision — multi-stage build:** build stage `elixir:1.18.4-otp-27` (matches CI's Elixir/OTP) with
  `build-essential` + **`cmake`** (brod's `crc32cer` NIF — the same dep CI needed), `MIX_ENV=prod`,
  `mix release chat_platform`. Runtime stage `debian:bookworm-slim` with ONLY runtime libs
  (`libstdc++6`/`openssl`/`libncurses6`/`ca-certificates`); ERTS is bundled by `mix release` so the
  runtime needs no Erlang/Elixir/mix. Non-root user, `CMD ["bin/chat_platform","start"]`. Final image ≈262 MB.
- **Decision — build context = `apps/backend`:** the umbrella root; `apps/web` is outside it (deploys
  separately, sub-slice 5). `.dockerignore` excludes `_build`/`deps`/per-app `test/` so host-built
  (macOS-arch) artifacts never leak into the linux build.
- **Decision — NO secrets in the image:** only source + config are COPYed; real secrets come from
  `-e`/secret store at runtime and `config/runtime.exs` enforces the fail-fast guard. Proven: a container
  run with NO secrets fails fast (`FATAL: DATABASE_URL is not set`).
- **Status:** Verified locally — `docker build` succeeds (262 MB); in-container the guard fires with no
  secrets, passes with valid dummy secrets (`runtime.exs` evaluates), and rejects a placeholder
  `SECRET_KEY_BASE`. `mix test` unchanged (200/73; 268 pg) — only Dockerfile/.dockerignore added, no app
  code. A full serving boot against managed Postgres is sub-slice 3 (deploy).

## [2026-06-18] Deploy sub-slice 1: prod fail-fast secret guard + runtime/release config + Repo supervision

- **Context:** The project had NEVER run as a booted server (only flag-gated/in-memory locally), and a
  deploy reality-check surfaced two foundational gaps: (1) NO app supervised its Repo at boot
  (`children = []`), so a real server would crash on the first DB request; (2) secrets fell back to
  insecure hardcoded placeholders silently (audit #4). There was also no `prod.exs`/`runtime.exs`/release,
  so `MIX_ENV=prod` couldn't even boot.
- **Decision — supervise Repos, gated OFF in `:test`:** each Repo-owning app (auth/user/conversation/
  message/notification) now starts its Repo at boot via `Application.get_env(:<app>, :start_repo, true)`.
  Default `true` (dev/prod start the Repo so the server serves DB requests); `config/test.exs` sets
  `start_repo: false` for all five, so `:test` does NOT start Repos at boot — `DataCase` starts them
  per-test and plain `mix test` stays Docker-free. Chose a runtime config flag (not `Mix.env`, which is
  unavailable in releases). Verified: gate is `false` in `:test`, `true` in `:dev`.
- **Decision — prod fail-fast secret guard:** `config/runtime.exs` runs its guard ONLY when
  `config_env() == :prod` (dev/test keep their placeholders, untouched). `SharedInfra.ProdConfig`
  refuses to boot if `SECRET_KEY_BASE`/`TOKEN_SECRET`/`OTP_SECRET` are missing or match a known insecure
  placeholder (`*-change-before-production`, `*-placeholder-*`), and requires `DATABASE_URL`. The guard
  is a PURE function (reads env / inspects a string) so it is unit-tested without booting prod
  (`SharedInfra.ProdConfigTest`, 8 plain tests). It covers EVERY insecure default found in inspection
  (tokens.ex, otp.ex, endpoint secret_key_base).
- **Decision — runtime/release config:** added `config/prod.exs` (minimal — its absence would make
  `import_config "#{config_env()}.exs"` fail under prod), `config/runtime.exs` (wires all 5 Repos from
  `DATABASE_URL` + pool/SSL, the endpoint from `SECRET_KEY_BASE`/`PHX_HOST`/`WEB_ORIGIN` with
  `server: true`, auth secrets, and Kafka brokers only if `KAFKA_BROKERS` is set), and a `releases:`
  block in the umbrella `mix.exs` bundling all 8 apps.
- **Hosting plan:** Fly.io (umbrella release) + managed Postgres + Vercel web; Kafka DEFERRED (flag-gated)
  — first deploy runs core chat (Postgres) ON, Kafka OFF, then enables Kafka once a broker is provisioned.
  See [DEPLOYMENT.md](../09-devops/DEPLOYMENT.md).
- **Status:** Code-verified. Plain `mix test` 192→200 (existing 192 intact + 8 guard tests; 0 Repo-connect
  leaks → Docker-free preserved); `postgres_integration` 260→268; release/runtime config compiles. NOT
  verified here (deploy-only, sub-slice 3): a real release boot, managed-PG TLS, public WSS, secret-store
  wiring. Containerize (2) and deploy (3) are next.

## [2026-06-18] Notification recipient fan-out (sub-slice c) + per-(event_id,recipient) idempotency; DataCase Repo-unlink fix

- **Context:** Final cross-service slice — notification-service now fans out one notification per
  conversation participant by reading its local `conversation_participants_readmodel` (built in (b))
  instead of writing one record per event. Completes the event-driven recipient flow with NO sync call.
- **Decision — fan-out with TWO-layer idempotency:** `apply_message_created/1` reads the active recipient
  set (`WHERE conversation_id=? AND active`, EXCLUDING `sender_user_id`) and `insert_all`s one
  notification per recipient. (1) The `notification_processed_events` ledger `(consumer, event_id)` stays
  the COARSE event-level gate. (2) A new UNIQUE index `notifications(source_event_id, recipient_user_id)`
  + `on_conflict: :nothing` is the DURABLE per-recipient guard — idempotent under redelivery/retry and
  tolerant of a participant set that grew between deliveries (only new recipients get inserted). Both in
  ONE `Repo.transaction`; commit-after-write unchanged.
- **Decision — cold-start limitation accepted:** if the read-model has no active participants for the
  conversation yet (the participant events haven't been consumed), fan-out notifies NOBODY (0 rows) and
  is NOT retried. Accepted eventual-consistency trade-off (seeding from creation events makes the common
  case fine); documented, not engineered around.
- **Decision — schema change:** `notifications` gains `recipient_user_id` (who is notified, vs
  `sender_user_id` = author). One-row-per-event behavior from the first notification slice is REPLACED by
  one-row-per-recipient (the prior test was updated, not deleted).
- **Test-infra fix (root-caused this slice):** the full `postgres_integration` umbrella suite was FLAKY —
  `Sandbox.checkout` intermittently exited with "no process". Cause: the `DataCase`s started the Repo via
  `Repo.start_link()` LINKED to the test process, so a single failing test's abnormal exit killed the
  shared Repo and cascaded checkout failures across the rest of that app's suite. Fix: `Process.unlink/1`
  the started Repo (the pattern user_service's DataCase already used) in the notification/conversation/
  auth/message DataCases. Pre-existing latent bug exposed by the added pg-test load; one-line, uniform,
  low-risk. Verified: full pg suite 5/5 green at 260 after the fix (was failing ~2/3 of runs before).
- **Status:** Implemented + verified. Plain `mix test` 192 (unchanged; Docker-free); `postgres_integration`
  257→260 (+3 net new fan-out tests; 5/5 stable). Key proofs pass: sender-excluded count (3 participants →
  2 notifications) and redelivery-idempotency (still 2). Live `kafka_integration` fan-out wiring green.
  **The cross-service recipient flow (a→b→c) is COMPLETE.**

## [2026-06-18] Out-of-order-tolerant read-model: soft-state + occurred_at LWW (reusable template) — sub-slice b

- **Context:** notification-service builds a LOCAL participant read-model from
  `conversation.participant_added/removed.v1` so (c) fan-out resolves recipients without a sync call.
  Unlike prior insert-only consumers, this read-model GROWS and SHRINKS and must be correct under
  redelivery AND out-of-order delivery. conversation-service emits each event in its own `Task`, so
  produce order ≠ logical order — the read-model CANNOT lean on Kafka per-partition ordering.
- **Decision — TWO independent correctness mechanisms (dedupe ≠ convergence; both required):**
  1. **Dedupe** same-event redelivery via the existing `notification_processed_events` ledger with a
     DISTINCT consumer name `notification-participants` (the `(consumer, event_id)` PK lets it share the
     table with the message→notification consumer, deduping independently). Atomic with the read-model
     write in ONE `Repo.transaction`.
  2. **Last-writer-wins** convergence for DIFFERENT events: store `last_event_at` and apply a state
     change ONLY when the incoming `occurred_at >= last_event_at`
     (`ON CONFLICT (conversation_id,user_id) DO UPDATE ... WHERE EXCLUDED.last_event_at >= table.last_event_at`).
- **Decision — soft state, NEVER hard-delete:** `active` boolean flips; rows are not deleted. A late
  `add` after a `remove` is not lost (LWW ignores it if older), and a `remove` arriving before its `add`
  just creates an inactive row. Hard insert/delete was rejected: it corrupts under reordering
  (remove-before-add deletes nothing, then add wrongly leaves the user active).
- **Rationale / reusable template:** this is the canonical pattern for ANY add/remove-fed read-model —
  dedupe ledger for redelivery + occurred_at LWW for convergence + soft state. Neither mechanism alone
  is sufficient: the ledger stops re-applying the SAME event; LWW makes DIFFERENT events converge to the
  latest-by-occurred_at state regardless of arrival order.
- **Caveat (honest) + future refinement:** `occurred_at` is stamped at EMIT time in conversation-service's
  `Task` (≈ persist time), not from the DB `joined_at`/`left_at`. It is a sound ordering proxy because each
  event is stamped right after its own persist, so two distinct API calls preserve real order even if Kafka
  delivery is reordered. If (a) ever batched/delayed emission this could drift; a stricter future refinement
  is to stamp `occurred_at` from the persisted `joined_at`/`left_at`. Not a blocker now.
- **Flag/topology:** a SECOND consumer (`ConversationParticipantsConsumer`) of `conversation.events.v1` in a
  DISTINCT group `notification-service-conversation-participants`, reusing the existing brod client (one
  client hosts multiple subscribers), behind its OWN flag `NOTIFICATION_PARTICIPANTS_CONSUMER_ENABLED`
  (default off) so it toggles independently of the message→notification consumer.
- **Status:** Implemented + verified. Plain `mix test` 191→192 (+1 plain invalid-event test, Docker-free;
  `NotificationService.Supervisor` children == [] with both flags off, confirmed at runtime);
  `postgres_integration` 251→257 (+5 convergence proofs — including the KEY out-of-order test: deliver the
  newer remove before the older add → final `active=false`). (c) fan-out is the NEXT slice.

## [2026-06-18] Cross-service data is EVENT-DRIVEN; ConversationService participant-change producer (sub-slice a)

- **Context:** notification-service must eventually fan out a notification per conversation PARTICIPANT,
  but `message.created.v1` carries the sender, not recipients. To resolve recipients WITHOUT a runtime
  sync call to ConversationService, notification-service will keep a LOCAL participant read-model fed by
  ConversationService events. This entry covers sub-slice (a): ConversationService emitting the
  participant-change events that set the contract; (b) read-model and (c) fan-out follow.
- **Decision — cross-service data via events, not sync API calls:** ConversationService publishes
  participant-change events; consumers build their own local read-models. Avoids runtime coupling
  (notification-service does not call ConversationService on the hot path) and matches the event-driven
  target. ConversationService was producer-less (deps were only ecto_sql/postgrex); added
  `{:shared_infra, in_umbrella: true}` + `brod`/`jason` and a fire-and-forget producer mirroring
  `MessageService.Messages.publish_message_created` exactly (flag `CONVERSATION_PUBLISH_ENABLED`,
  default off; `Task.start`; try/rescue/catch; default `NoopProducer` ⇒ Docker-free; never couples
  the create/add/remove result to the broker).
- **Decision — emit from ALL THREE membership points:** conversation creation (one `participant_added`
  per initial participant, AFTER the tx commits), explicit add (`participant_added`), and remove
  (`participant_removed`). A read-model fed only by later add/removes would MISS every participant
  created with the conversation. Emitting `participant_added` per initial participant (rather than a
  separate `conversation.created` seed) keeps the contract to TWO event types and a uniform read-model
  update path — the smaller, cleaner diff. Contract (sets sub-slice b):
  `participant_added.v1 → {conversation_id, user_id, role, added_by}`,
  `participant_removed.v1 → {conversation_id, user_id, removed_by}`; topic `conversation.events.v1`,
  key `conversation_id`.
- **Decision — BrodProducer client name made per-call configurable (minimal de-hardcoding):** the
  adapter hardcoded `:message_service_kafka_client`. Now `produce/4` reads `opts[:client]`, defaulting
  to `client_name/0` (the message-service client) so message-service's call site is byte-for-byte
  unchanged; conversation-service passes `client: :conversation_service_kafka_client` and runs its OWN
  flag-gated brod client. A shared producer base extraction remains DEFERRED — this is only the minimal
  change needed for two producers.
- **Decision — notification-service consumes `participant_removed` despite the catalog omission:** the
  KAFKA_EVENT_CATALOG "Consumed by" list omits notification-service for `participant_removed`, but the
  read-model needs removals; the doc was corrected (trust the requirement, not the doc).
- **Status:** Implemented + verified (sub-slice a only). Plain `mix test` 186→191 (+5 plain producer
  tests, Docker-free; `ConversationService.Supervisor` children == [] with flags off, confirmed at
  runtime); `postgres_integration` 245→251 (+1 emit-after-persist wiring test proving all three points).
  Sub-slices (b) notification read-model and (c) fan-out are NOT done.

## [2026-06-18] notification-service: first missing service built; per-service idempotency ledger

- **Context:** Audit finding #6 — 5 documented services have no code. notification-service is the
  first to build: it consumes `message.created.v1` and reuses the proven `(consumer, event_id)`
  dedupe pattern. Two design questions had to be settled because this is the blueprint the other
  4 services copy.
- **Decision A — per-service idempotency ledger (NOT a shared one):** notification-service owns its
  own `notification_processed_events` table (its own `NotificationService.Repo`), rather than
  reusing message-service's `processed_events`. **Rationale:** the target is independent
  microservices each owning their data; a shared ledger couples two services through one table (the
  shared-database anti-pattern) — message-service would "own" rows notification-service depends on.
  The only pull toward sharing was avoiding a table-name clash in today's single physical Postgres;
  a service-prefixed table name solves that without coupling, and when services get separate
  databases each carries its own ledger unchanged. **Blueprint: every future service gets
  `<service>_processed_events` in its own Repo.** The `(consumer, event_id)` PK is kept verbatim so
  the dedupe core copies unchanged and supports multiple internal consumers later.
- **Decision B — Repo started WITH the consumer flag; tests start their own Repo:** the Repo is
  never unconditionally supervised. With `NOTIFICATION_CONSUMER_ENABLED` OFF (default),
  `NotificationService.Application.children/0` returns `[]` → no Repo/client/consumer at boot →
  plain `mix test` stays Docker-free. With the flag ON, children = `[Repo, brod client, consumer]`
  together, so the consumer can persist in dev/prod (this closes the latent "Repo not supervised"
  gap that message-service's projection consumer still has, scoped to the new app). The Repo-only
  `postgres_integration` idempotency test gets its Repo from `DataCase` setup (`Repo.start_link` +
  `Sandbox.checkout`), **decoupled from the flag** — so the exactly-once proof works regardless.
- **Decision — dedupe core COPIED, not extracted:** `NotificationService.Notifications.apply_message_created/1`
  and the `brod_group_subscriber_v2` cb are copied from the conversation-summary consumer rather
  than refactored into a `shared_infra` base. Extracting a shared base is a separate future refactor
  (DEFERRED — not done now, to avoid an unrelated rewrite). Per-service copies are acceptable while
  the pattern stabilizes across the first few services.
- **Decision — recipient fan-out DEFERRED:** the first slice writes ONE notification record per
  event (`type: "message_created"`, no recipient). `message.created.v1` carries `sender_user_id`,
  not recipients, so per-participant fan-out needs ConversationService participant data
  (cross-service) — a later slice. This proves the new service end-to-end first.
- **Status:** Implemented + verified. Exactly-once proof (`notifications_test.exs`,
  postgres_integration) and live broker round-trip (`message_created_consumer_integration_test.exs`,
  kafka_integration) both pass; plain `mix test` unchanged at 186; pg 243→245.

## [2026-06-18] First stateful, idempotent consumer = the dedupe blueprint for notification-service

- **Context:** The log/ack consumer proved the pipe but does nothing. The next consumer must
  actually maintain state from `message.created.v1`, and must be exactly-once under brod's
  at-least-once redelivery. Whatever pattern it establishes will be copied verbatim by the
  future notification-service, so it has to be the canonical one.
- **Decision:** Build `MessageService.Projections.ConversationSummary` — a per-conversation
  message-summary projection — with idempotency enforced by a generic `processed_events` ledger
  keyed `(consumer, event_id)`. In ONE `Repo.transaction`: `INSERT ... ON CONFLICT DO NOTHING`
  into the ledger (affected count `1` = NEW, `0` = DUPLICATE), and only when NEW apply the
  `conversation_message_summaries` upsert (atomic `message_count` increment + last-message set).
  Both commit or both roll back together.
- **Decision — commit ordering (at-least-once):** the consumer
  (`MessageService.Events.ConversationSummaryConsumer`) commits the offset ONLY after the DB
  transaction succeeds. Transient DB error → no commit → redeliver. **Structurally-invalid /
  poison event (malformed `event_id`/`conversation_id`) → log + commit (skip).** This last point
  was hardened after a live run: historical topic events with non-UUID ids raised
  `Ecto.ChangeError` and, treated as transient, wedged the partition in an infinite retry.
  `fetch_uuid/2` now validates UUIDs up front so malformed ids surface as `{:error, :invalid_event}`
  (poison → skip), never retry.
- **Decision — separate consumer group + flag:** distinct group `message-service-conversation-summary`
  and its own flag `KAFKA_PROJECTION_CONSUMER_ENABLED` (default off), independent of the log
  consumer. The brod client gate (`MessageService.Application`) now also starts when this flag is on.
  Default off ⇒ nothing connects at boot, plain `mix test` stays Docker-free.
- **Decision — tables are NOT Ecto migrations:** the two tables live in
  `infra/docker/postgres/init/030_message_projections.sql`, applied manually to `chat_platform_test`,
  consistent with the existing init-SQL convention (no Ecto migrations in this repo).
- **Rationale:** The ledger-in-the-same-transaction pattern is the simplest construction that is
  provably exactly-once without distributed coordination; keying by `(consumer, event_id)` lets
  many consumers share one ledger table while each applies an event once. Poison-skip prevents a
  single bad event from halting all downstream projections.
- **Status:** Implemented + verified. Exactly-once proof (`conversation_summary_projection_test.exs`,
  postgres_integration) and live broker round-trip (`conversation_summary_consumer_integration_test.exs`,
  kafka_integration) both pass; plain `mix test` unchanged at 186.

## [2026-06-18] Minimal log/ack Kafka consumer (completes the pipe, no behavior coupling)

- **Context:** `message.created.v1` reaches the broker but nothing consumes it. The milestone
  needs a consumer; the first one should prove the pipe without risk.
- **Decision:** A MINIMAL consumer — `MessageService.Events.MessageCreatedLogConsumer`, a
  `brod_group_subscriber_v2` callback module that decodes + **logs + commits** the offset, with
  NO DB writes / fanout / notifications / behavior coupling. Flag-gated by `KAFKA_CONSUMER_ENABLED`
  (default off), supervised in `MessageService.Application` (started only under the flag, after the
  brod client; the client gate now also starts when the consumer is enabled). Reuses the existing
  `:message_service_kafka_client`. group_id `message-service-log-consumer`.
- **Decision — brod_group_subscriber_v2 over the old `SharedInfra.Kafka.Consumer` poll behaviour:**
  the poll behaviour (subscribe/poll/ack) is a model mismatch for brod's push/callback subscriber;
  it stays unused.
- **Poison-message handling:** a JSON-undecodable / handler-raising message is logged and the offset
  is STILL committed (no crash-loop / partition wedge).
- **CARRIED-FORWARD CONSTRAINT (at-least-once):** brod commits AFTER handling → redelivery is
  possible. The log consumer is safe (no side effects, idempotent). The NEXT **stateful** consumer
  (projections/fanout/notifications) MUST dedupe on the envelope `event_id` (present) or use
  idempotent upserts — do not bake in a non-idempotent handler.
- **Status:** Implemented + verified live (`--include kafka_integration` produce→consume round-trip,
  1 passed). Plain `mix test` Docker-free (flag off → no consumer). Real reactive consumer = next slice.

## [2026-06-18] brod-backed Kafka producer adapter: async-only, :hash partitioner

- **Context:** Making `message.created.v1` actually reach a broker (it was emitted through the
  boundary but swallowed by `NoopProducer`). The emit point runs inline on the message-create path.
- **Decision — async only:** `SharedInfra.Kafka.BrodProducer` uses **`:brod.produce/5` (async)**,
  NEVER `produce_sync`. Additionally, the emit at `Messages.publish_message_created/1` is wrapped in
  **`Task.start`** (unlinked). Rationale: the existing `try/rescue/catch` protects *correctness* but
  not *latency* — a sync produce (or even a lazy producer-start / metadata fetch) could stall a
  create on broker latency. Async + Task.start decouples create latency entirely from the broker
  (fire-and-forget for BOTH correctness and latency). Proven: create succeeds even when the producer
  raises (step-2 test), and the create path never awaits an ack.
- **Decision — `:hash` partitioner** on the key (`conversation_id`): preserves per-conversation
  message ordering within a topic. This depends on a stable partition count → see topic decision.
- **Decision — topic partitions:** added a one-shot `kafka-init` docker-compose service running
  `create-topics.sh` so `message.events.v1` is created with the declared **6 partitions** before
  produce, instead of `AUTO_CREATE_TOPICS` giving 3.
- **Decision — jason reused:** envelope JSON encoding uses jason (already in the lock); declared as a
  direct dep of `shared_infra` so the module is in compile scope (no new package). `Jason.encode/1`
  (not `encode!`) — encode errors are logged + returned `{:error,_}`, never raised at the caller.
- **Flag-gating:** brod client started ONLY when `KAFKA_PRODUCER_ADAPTER=brod` selects the adapter
  (`MessageService.Application` conditional child); default stays `NoopProducer` → no client → no
  connect → plain `mix test` Docker-free.
- **Status:** Implemented + verified against a live broker (`--include kafka_integration`, 1 passed,
  6 partitions confirmed). **Consumer side is a separate later slice.**

## [2026-06-18] First Kafka event (`message.created.v1`) is fire-and-forget

- **Context:** Wiring the first real producer. A message create persists to the durable store
  (Postgres) and is the natural producer hook. Risk: coupling event publish to message creation
  could make creates fail when the broker is down.
- **Decision:** Publish `message.created.v1` **fire-and-forget / best-effort** after a successful
  persist (`MessageService.Messages.publish_message_created/1`): the `{:ok, response}` is computed
  and returned **independently**, and the publish is wrapped in `try/rescue/catch` — any envelope
  error, producer error, exception, or exit is caught + logged, **never propagated**. Flag-gated by
  `KAFKA_PUBLISH_ENABLED` (default off); default producer adapter stays the non-connecting
  `NoopProducer`. Topic `message.events.v1`, key `conversation_id`, envelope via
  `SharedInfra.Events.Envelope`.
- **Rationale:** Durability MUST NOT depend on broker availability — losing an event is acceptable
  (consumers reconcile / events are an optimization here), losing a message is not. Proven by a test
  where the producer raises and the create still succeeds + persists.
- **Status:** Implemented + tested (Docker-free, fake adapter). Live broker-backed adapter + consumer
  side: still pending. `correlation_id`/`event_id` are generated locally for now (no request-scoped
  trace id threaded yet — future work).

## [2026-06-18] Kafka: brod chosen (decimal-free); envelope contract before producing; brod compile deferred

- **Context:** Starting the Kafka event backbone (0% wired). Driver candidates: brod, kafka_ex,
  broadway_kafka. The Xandra lesson: verify dependency compatibility BEFORE adopting.
- **Decision — driver:** **brod** — it is `decimal`-free (deps: kafka_protocol/crc32cer/snappyer),
  so unlike Xandra it does NOT conflict with the project's `decimal ~> 3.0` / `ecto 3.14`.
  `mix deps.get` confirmed clean resolution (decimal/ecto unchanged).
- **Blocker found (deferred, not hacked):** brod **resolves but does not compile** in this
  environment — its transitive NIF `crc32cer` requires a C toolchain (`cmake`) that is not
  installed (`make: cmake: No such file`). So the brod dependency is **deferred to the
  producer-wiring slice (c)**, gated on resolving the NIF build (install cmake, or a
  pure-Erlang CRC path / NIF-free driver). The (a)+(b) scaffolding below needs no broker
  driver, so it landed brod-free.
- **Decision — envelope contract first:** added `SharedInfra.Events.Envelope` (build/validate the
  documented standard envelope) and a dormant `SharedInfra.Kafka.Producer` dispatcher with a
  non-connecting `NoopProducer` default (mirrors `Scylla.Client`/`UnavailableClient`), BEFORE any
  producer hook — so every future producer emits a consistent, validated shape.
- **Rationale:** define the contract + safe dispatcher seam now (pure Elixir, Docker-free, zero
  behavior change); add the real broker driver + first event flow once the NIF/toolchain blocker
  is cleared. Adapter boundary keeps the driver swappable.
- **Status:** (a) dispatcher + NoopProducer + (b) envelope contract: implemented, dormant.
  **Update 2026-06-18 (slice c, step 1): brod `~> 4.0` re-added and now COMPILES** (cmake 4.3.3
  installed; `crc32cer` NIF builds). brod 4.5.5 / kafka_protocol 4.3.4 / crc32cer 1.1.3 in the
  lock. brod is **present but unused** — dispatcher still defaults to `NoopProducer`, nothing
  connects, test counts unchanged (183/56). Live brod-backed adapter + first event flow
  (`message.created.v1`) remain for slice (c) step 2.
- **Build-tool requirement (RESOLVED in CI, 2026-06-18 step 1.5):** the backend needs a **C
  toolchain + cmake** to build brod's `crc32cer` NIF. `.github/workflows/backend-ci.yml` now
  installs it (`apt-get install -y cmake build-essential`) after `setup-beam` and before
  `mix deps.get`/`compile` (workflow lines 31-32). Final proof is the next CI run on push.
  Local dev requires the same (e.g. `brew install cmake`).

## [2026-06-18] Message durability on Postgres now; ScyllaDB deferred

- **Context:** Messages were only ever stored in-memory (no live persistence). The
  intended high-write backend is ScyllaDB, but adding the Elixir driver (Xandra) is
  blocked by a hard dependency conflict — `ecto 3.14` requires `decimal ~> 3.0` while
  every Xandra ≥ 0.15 requires `decimal ~> 1.7 or ~> 2.0` (disjoint; an Ecto downgrade
  was out of scope/risky).
- **Decision:** Implement real message durability on **PostgreSQL now**, behind the
  existing swappable `MessageStore` adapter boundary (`MESSAGE_STORE_ADAPTER=postgres` →
  `MessageService.MessageStore.PostgresAdapter`, new `MessageService.Repo` + `messages`/
  `message_receipts` tables). Defaults are unchanged (QueryPlan/in-memory), so plain
  `mix test` stays Docker-free.
- **ScyllaDB remains the documented long-term backend** for high write volume, **deferred
  to a future milestone** — revisit when write-scale justifies it or when a Xandra release
  supports `decimal ~> 3.0`. The adapter boundary makes swapping backends a contained change.
- **Rationale:** Durability is a correctness gap we can close immediately on infrastructure
  the project already runs (Postgres), without an ecto/decimal downgrade or a blind driver
  choice. The cross-day `bucket_date` partition limitation is Scylla-specific and does **not**
  apply to the Postgres store (no partitions; lookups by message_id / conversation_id).
- **Status:** Implemented (Postgres adapter + integration tests). Scylla live driver: deferred.
