# Decision Log

Architecture decisions, newest first. Each entry: context → decision → rationale → status.

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
