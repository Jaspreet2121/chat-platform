# Session Log

## [2026-06-18] Slice: cross-service (a) — ConversationService participant-change producer
- Status: ✅ green (plain producer contract tests + live-DB emit-after-persist wiring)
- Context: recipient fan-out is event-driven (no sync calls). Sub-slice (a): ConversationService emits participant-change events that notification-service's future read-model (b) + fan-out (c) consume. ONLY (a).
- Files changed: `apps/shared_infra/lib/shared_infra/kafka/brod_producer.ex` (de-hardcode: `produce/4` selects client via `opts[:client]`, default `client_name/0` = message-service client → message_service UNCHANGED); `apps/conversation_service/mix.exs` (+`{:shared_infra, in_umbrella: true}`, `{:brod, "~> 4.0"}`, `{:jason, "~> 1.4"}`, `extra_applications: +:crypto`); new `apps/conversation_service/lib/conversation_service/participant_events.ex` (fire-and-forget emit helpers + `client_name/0` `:conversation_service_kafka_client`); `conversations.ex` (emit one `participant_added` per initial participant AFTER tx commit); `participants.ex` (emit `participant_added` on add, `participant_removed` on remove); `application.ex` (flag-gated brod client, `children/0 == []` unless brod adapter selected AND `CONVERSATION_PUBLISH_ENABLED`); `config/config.exs` (`:conversation_service, :kafka` + `conversation_publish_enabled` flag); `test_helper.exs` (+`kafka_integration` exclude, proactively); new plain test `participant_events_test.exs` + new pg wiring test `participant_events_integration_test.exs`.
- Event-flow behavior: with `CONVERSATION_PUBLISH_ENABLED`, after a successful persist, ConversationService emits to `conversation.events.v1` (key `conversation_id`), fire-and-forget (`Task.start`, try/rescue/catch). Contract (sets sub-slice b): `participant_added.v1 → {conversation_id, user_id, role, added_by}`, `participant_removed.v1 → {conversation_id, user_id, removed_by}`. Initial participants emitted as `participant_added` (one each, role owner for creator else member) so the read-model is complete from added/removed alone (no separate created-seed). Default off ⇒ default NoopProducer ⇒ nothing connects; create/add/remove NEVER coupled to the broker.
- Config/env flags: `CONVERSATION_PUBLISH_ENABLED` (default off) gates the brod client + emission; `:conversation_service, :kafka` brokers/client_id (reuses `KAFKA_BROKERS`). Live producing needs `KAFKA_PRODUCER_ADAPTER=brod`.
- Verification: mix format clean; mix compile --warnings-as-errors clean (conversation_service compiles with new deps); `mix test` → **191 passed / 65 excluded, 0 failures** (186 baseline + 5 NEW PLAIN producer tests; all 186 intact → Docker-free; +1 excluded = the new pg wiring test); **confirmed `ConversationService.Supervisor` children == [] and adapter == NoopProducer with default env (runtime check)** → nothing connects at boot; `mix test --include postgres_integration` → **251 passed, 0 failures** (245 + 5 + 1; the emit-after-persist wiring test proves create emits one per initial participant + add + remove all emit after a real DB commit); web untouched.
- Non-negotiables honored: fire-and-forget (publish failure never breaks create/add/remove — proven by the failing-adapter plain test + the Task.start wrap); emitted from ALL THREE membership points; flag-gated default off; brod client never started unconditionally (children == [] confirmed); message_service producer behavior unchanged (client-name default preserved); test_helper kafka exclude added; no read-model/fan-out built; no shared producer-base extraction (still deferred).
- Caveats / next: sub-slice (b) notification participant read-model + (c) fan-out remain. Cold-start/ordering race (message.created before read-model populated → notifies nobody) accepted, to be documented in (b)/(c). conversation.participant_removed catalog "Consumed by" omitted notification-service — doc corrected (read-model needs removals).

## [2026-06-18] Slice: notification-service — FIRST missing service built (scaffold + idempotent consumer)
- Status: ✅ green (incl. live produce→consume round-trip + exactly-once unit proof)
- Context: audit finding #6 — 5 documented services have no code. This builds the FIRST: notification-service, a new umbrella app consuming `message.created.v1` → one notification record, reusing the proven `(consumer, event_id)` dedupe pattern. Blueprint for the other 4.
- Decisions: **(A) per-service idempotency ledger** — notification-service owns `notification_processed_events` (its own Repo), NOT message-service's shared `processed_events`; avoids coupling services through one table (shared-DB anti-pattern); service-prefixed name dodges the single-physical-DB name clash; blueprint = `<service>_processed_events` per service. **(B) Repo gated WITH the consumer flag** — `children/0 == []` when `NOTIFICATION_CONSUMER_ENABLED` off (Docker-free, nothing connects); `[Repo, brod client, consumer]` when on; the Repo-only pg test starts its Repo via its own DataCase, decoupled from the flag. **Dedupe core COPIED, not extracted** to shared_infra (deferred refactor). **Recipient fan-out DEFERRED** (message.created.v1 has sender not recipients → needs ConversationService data).
- Files created: new umbrella app `apps/backend/apps/notification_service/` — `mix.exs`, `lib/notification_service.ex`, `repo.ex`, `application.ex` (flag-gated children), `notifications.ex` (`apply_message_created/1` dedupe core, `@consumer "notification"`), `events/message_created_consumer.ex` (`brod_group_subscriber_v2`, distinct group `notification-service-message-created`, own client `:notification_service_kafka_client`), `schemas/processed_event.ex` (maps `notification_processed_events`), `schemas/notification.ex`, `test/test_helper.exs` (excludes FIRST), `test/support/data_case.ex`, two tests; new `infra/docker/postgres/init/040_notifications.sql` (`notification_processed_events` + `notifications`, applied to `chat_platform_test`). Files edited: `config/config.exs` (ecto_repos + `:kafka` + `consumer_enabled` flag), `config/dev.exs` + `config/test.exs` (Repo config).
- Event-flow behavior: with `NOTIFICATION_CONSUMER_ENABLED`, the consumer (distinct group, reusing topic `message.events.v1`) decodes each `message.created.v1` and in ONE `Repo.transaction` inserts the ledger row (`ON CONFLICT DO NOTHING`) then, only when new, inserts ONE notification row (`type: "message_created"`). Commit-after-write; transient DB error → no commit (redeliver); poison/malformed → log + commit (skip). Default off ⇒ nothing connects at boot.
- Config/env flags: `NOTIFICATION_CONSUMER_ENABLED` (default off) gates Repo+client+consumer together; `:notification_service, :kafka` brokers/client_id (reuses `KAFKA_BROKERS`).
- Verification: mix format clean; mix compile --warnings-as-errors clean (new app compiles + auto-registered in the umbrella; CI needs no change — runs the whole umbrella, cmake already added); `mix test` → **186 passed / 64 excluded, 0 failures** (passed UNCHANGED → Docker-free; new app's Repo/consumer flag-off → nothing starts; +3 excluded = 2 postgres_integration + 1 kafka_integration); `mix test --include postgres_integration` → **245 passed, 0 failures** (243 baseline + 2 new; exactly-once test passes: same event_id twice → applied then duplicate, ONE notification row + one ledger row; distinct event → 2); **live `mix test --include kafka_integration` wiring → 1 passed** (logs show historical poison events `skipping (commit)` then our event applied + the notification row read back); web untouched.
- Non-negotiables honored: Repo/consumer never started unconditionally (flag-gated, default off, children=[]); plain mix test Docker-free + passed unchanged at 186; test_helper excludes added FIRST; per-service ledger (no cross-service coupling); dedupe core copied not refactored (no unrelated rewrite); tables via init-SQL (no Ecto migration).

## [2026-06-18] Slice: Kafka step 5 phase 2 — FIRST STATEFUL, IDEMPOTENT consumer (conversation summary)
- Status: ✅ green (incl. live produce→consume round-trip + exactly-once unit proof)
- Files changed: new `infra/docker/postgres/init/030_message_projections.sql` (`processed_events` ledger keyed `(consumer, event_id)` + `conversation_message_summaries` projection; applied to `chat_platform_test`); new schemas `processed_event.ex`, `conversation_message_summary.ex`; new `lib/message_service/projections/conversation_summary.ex` (`apply_message_created/1` — the reusable idempotency core); new `lib/message_service/events/conversation_summary_consumer.ex` (`brod_group_subscriber_v2` cb); `lib/message_service/application.ex` (projection-consumer child + client gate extended to include it + `kafka_projection_consumer_enabled?` + `conversation_summary_child_spec`, distinct group `message-service-conversation-summary`); `config/config.exs` (`kafka_projection_consumer_enabled` flag, default off); new tests `conversation_summary_projection_test.exs` (postgres_integration, exactly-once) + `conversation_summary_consumer_integration_test.exs` (kafka_integration, live wiring); docs.
- Idempotency behavior: in ONE `Repo.transaction`, `INSERT ... ON CONFLICT DO NOTHING` into `processed_events` (affected count 1 = new → apply summary upsert with atomic `message_count` increment; 0 = duplicate → skip). Commit ordering: DB tx ok → `{:ok, :commit}`; transient DB error → no commit (redeliver); structurally-invalid/poison event → log + commit (skip). Returns `{:ok, :applied} | {:ok, :duplicate} | {:error, term}`. Default off ⇒ nothing connects at boot.
- Errors fixed mid-slice: (1) `:utc_datetime_usec` rejected the second-precision DateTime from `DateTime.from_iso8601("...10:00:00Z")` — `parse_timestamp/2` now forces microsecond precision `{_, 6}`. (2) **Poison-wedge found on the live broker:** historical topic events with non-UUID `event_id`s raised `Ecto.ChangeError`, which (as a transient error) wedged the partition in an infinite retry — added `fetch_uuid/2` to validate UUIDs up front so malformed ids surface as `{:error, :invalid_event}` (skip+commit), never retry. (3) Wiring test failed in teardown only: `Repo.start_link/0` links the Repo to the test process, so a `Sandbox.mode(Repo, :manual)` on_exit ran against an already-dead Repo — removed it (the linked Repo tears down automatically).
- Verification: mix format clean; mix compile --warnings-as-errors clean; `mix test` → **186 passed / 61 excluded, 0 failures** (passed UNCHANGED → Docker-free; +3 excluded = 2 postgres_integration + 1 kafka_integration); `mix test --include postgres_integration` → **243 passed, 0 failures** (241 baseline + 2 new; the exactly-once test passes: same event_id twice → `applied` then `duplicate`, `message_count == 1`; distinct event → 2); **live `mix test --include kafka_integration` wiring → 1 passed** (logs show poison events `skipping (commit)` then our event applied + the projection/ledger rows read back); web untouched.
- Non-negotiables honored: atomic dedupe+projection in one `Repo.transaction` (`ON CONFLICT DO NOTHING`); commit only after DB write; ledger keyed `(consumer, event_id)`; distinct group + separate flag, default off; consumer never started unconditionally; tables via init-SQL (no Ecto migration); plain mix test Docker-free.
- Blueprint note: `ConversationSummary` is the dedupe pattern notification-service copies verbatim — `(consumer, event_id)` ledger + atomic upsert in one transaction; poison-skip prevents one bad event halting all projections.

## [2026-06-18] Inspection pass: first STATEFUL/idempotent consumer (Kafka step 5 phase 1, no code)
- Status: ℹ️ inspect-only; nothing changed but this note. Phase 2 awaiting approval.
- Findings: dedupe key = envelope top-level `event_id` (UUID per produced event, `messages.ex` build_message_created_envelope); payload carries `conversation_id`/`message_id`/`sender_user_id`/`message_type`/`created_at` — all the projection inputs. `MessageService.Repo` + Ecto are in place; `Repo.transaction` is used (conversation_service `conversations.ex:160`) and `Repo.insert_all`/`on_conflict` upsert is used (`message_store.ex:616`) — so atomic dedupe+upsert is idiomatic here. Tables come from `infra/docker/postgres/init/0xx_*.sql` (applied to `chat_platform_test` manually; DataCase notes it) — a new projection + dedupe table = a new `030_*.sql`. message_service test_helper ALREADY excludes BOTH `postgres_integration` and `kafka_integration` (no new exclude needed). `brod_group_subscriber_v2.handle_message -> {:ok, :commit, state}` commits AFTER handling.
- Assessment (smallest safe slice): projection = **per-conversation message summary** (`conversation_id` PK, `message_count`, `last_message_id`, `last_message_at`) — the `message_count` increment is exactly the non-idempotent op that proves dedupe. Dedupe = a `processed_events` table keyed by `(consumer, event_id)`; in ONE `Repo.transaction`: `Repo.insert_all(processed_events, on_conflict: :nothing)` → if affected count == 1 (new) apply the summary upsert (`on_conflict: [inc: [message_count: 1], set: [...]]`), if 0 (duplicate) skip. Atomic → crash between dedupe and projection rolls back → safe redelivery. Commit ordering: DB tx succeeds → `{:ok, :commit, state}`; tx fails → `{:ok, state}` (no commit → redeliver). DISTINCT consumer group (`message-service-conversation-summary`) + SEPARATE flag `KAFKA_PROJECTION_CONSUMER_ENABLED` (default off) so log + stateful consumers toggle independently; client-start gate extended to (producer-brod OR log-consumer OR projection-consumer). Put the projection logic in a `MessageService.Projections.ConversationSummary.apply_message_created/1` (Repo.transaction) callable by BOTH the cb and tests.
- Tests: the EXACTLY-ONCE proof is a **postgres_integration** test (Repo only, deterministic) calling `apply_message_created/1` TWICE with the same `event_id` → `message_count == 1`; two distinct events → `2`. A separate **kafka_integration** test proves wiring (produce → consume → summary row). KEY test-setup risk: the brod consumer worker is a SEPARATE process, so a Sandbox `checkout` (DataCase) connection is NOT visible to it — the kafka wiring test should NOT use the sandbox; start the Repo, let the consumer COMMIT real rows, assert via Repo, and clean up by unique conversation_id/event_id in on_exit (or use shared-sandbox mode). The idempotency logic test avoids this entirely (Repo-only, no broker, can use DataCase sandbox since it calls apply_message_created in-process).
- Risks flagged: double-apply (prevented by atomic processed_events gate), commit-before-write loss (commit only after tx success), non-atomic dedupe (one transaction), consumer-in-boot (flag-only, default off), plain mix test needing infra (both tests tagged + already excluded), cross-process sandbox (use real-writes+cleanup for the kafka test). Pattern to copy into notification-service: `(consumer, event_id)` ledger + atomic upsert. Flag off (default) = zero behavior change; flag on = writes only its own `processed_events` + summary tables, no user-facing path.

## [2026-06-18] Slice: Kafka step 4 (ii) — MINIMAL log/ack CONSUMER (pipe proven end-to-end)
- Status: ✅ green (incl. live produce→consume round-trip)
- Files changed: new `apps/message_service/lib/message_service/events/message_created_log_consumer.ex` (`brod_group_subscriber_v2`, log/ack); `apps/message_service/lib/message_service/application.ex` (flag-gated consumer child + client gate now `producer-brod OR consumer-enabled`); `apps/message_service/mix.exs` (+`{:brod, "~> 4.0"}`, `{:jason, "~> 1.4"}` — both already locked, declared for `@behaviour`/`Record.extract`/`Jason.decode` compile scope); `config/config.exs` (`kafka_consumer_enabled` flag, default off); `apps/message_service/test/test_helper.exs` (+`kafka_integration` exclude, FIRST); new `apps/message_service/test/message_service/message_created_consumer_integration_test.exs` (`@tag :kafka_integration`); fixed flaky step-2 `message_created_event_test.exs` (scoped assertions to a unique conversation_id); docs.
- Event-flow behavior: with `KAFKA_CONSUMER_ENABLED`, a `brod_group_subscriber_v2` (group `message-service-log-consumer`, topic `message.events.v1`, reusing `:message_service_kafka_client`) consumes `message.created.v1`, logs it, returns `{:ok, :commit, state}` (poison/undecodable → log + commit, no wedge). NO DB/fanout/behavior coupling. Started ONLY under the flag in `MessageService.Application` (`application.ex` `kafka_consumer_enabled?`/`kafka_consumer_child_spec`) — default off → no consumer, Docker-free. The client gate also starts the client when the consumer is enabled.
- Config/env flags: `KAFKA_CONSUMER_ENABLED` (default off); reuses brokers + the brod client from the producer slice.
- Verification: mix format clean; mix compile --warnings-as-errors clean; `mix test` → **186 passed / 58 excluded** (passed UNCHANGED → Docker-free; +1 excluded = the consumer kafka_integration test); message_service alone ×3 seeds → 37 passed/5 excluded each (FIXED a flaky step-2 test: the Task-based async publish + global capture pid let a stray Task trip the next test's `refute_received`; scoped every assertion to a per-test unique conversation_id); `mix test --include postgres_integration` → **241 passed, 0 failures** (per-app breakdown; a piped count again showed a spurious 200 due to the fire-and-forget warning log interleaving); **live `mix test --include kafka_integration` consumer round-trip → 1 passed** (logs show real `kafka consume message.created.v1 key=... event_id=...`); web lint/typecheck/build ok (untouched).
- Non-negotiables honored: consumer started ONLY under the flag (never unconditional); minimal log/ack only (no side effects/behavior coupling); test_helper kafka exclude added BEFORE the tagged test; poison message committed (no crash-loop).
- Test determinism note: the consumer integration test uses `begin_offset: :earliest` on a fresh unique group (deterministically reads the produced message, matched by unique key) — PRODUCTION uses `:latest` (no replay on deploy).
- Caveats / carried-forward: this consumer is log/ack only — the REAL reactive consumer (fanout/notifications) is the next slice and MUST dedupe on the envelope `event_id` (at-least-once). `event_id`/`correlation_id` still generated locally.
- Doc corrections: KAFKA_EVENT_CATALOG message.created.v1 now shows BOTH producer + minimal consumer (pipe proven).

## [2026-06-18] Inspection pass: Kafka CONSUMER (step 4 phase 1, no code/deps changed)
- Status: ℹ️ inspect-only; nothing changed but this note. Phase 2 awaiting approval.
- Findings: `SharedInfra.Kafka.Consumer` (`consumer.ex:9-11`) is a POLL-based behaviour (subscribe/poll/ack) — a poor fit for brod's push/callback model and unused; no consumer adapter is selected from config (no producer-style dispatcher symmetry). brod ships `brod_group_subscriber_v2` (modern group subscriber w/ offset commit) — start via `:brod.start_link_group_subscriber_v2(config)` (`brod.erl:927-931`); config map `%{client, group_id, topics, cb_module, init_data?, consumer_config?, group_config?, message_type?}` (`brod_group_subscriber_v2.erl:64-73`); required callbacks `init/2 -> {:ok, state}` and `handle_message/2 -> {:ok, :commit, state} | {:ok, :ack, state} | {:ok, state}` (`:88-94`). Returning `{:ok, :commit, _}` commits AFTER handling → **at-least-once** (redelivery possible → real consumers must be idempotent). A brod client hosts both producers and consumers, so the consumer can reuse the existing `:message_service_kafka_client`. ⚠️ **`apps/message_service/test/test_helper.exs` excludes only `postgres_integration`, NOT `kafka_integration`** — must add the kafka exclude there BEFORE any tagged consumer test (twice-burned lesson; shared_infra already has it). Producer integration-test pattern to mirror: start client in setup, `on_exit :brod.stop_client`, capture via a test pid in app env.
- Assessment (minimal slice): a flag-gated (`KAFKA_CONSUMER_ENABLED`, default off) supervised `brod_group_subscriber_v2` cb module that decodes + logs `message.created.v1` and returns `{:ok, :commit, state}` — NO projection/fanout/behavior coupling (naturally idempotent: log-only). Owner = **message_service** for the minimal slice (reuse its brod client + flag-gated child in `MessageService.Application`); the REAL reactive consumer (fanout/notifications) belongs in realtime_gateway/notification-service later. group_id e.g. `message-service-log-consumer`, topic `message.events.v1`, `consumer_config: [begin_offset: :latest]` (no history replay). ONE `@tag :kafka_integration` round-trip test (produce → consumer handles → assert via test-pid hook), excluded by default. Risks: consumer child must be flag-only (never unconditional in Application.start); the brod-client gate must also start the client when the consumer is enabled (consumer needs the client); add the message_service test_helper kafka_integration exclude first; commit-after-handle is at-least-once → the NEXT stateful consumer MUST dedupe (use the envelope `event_id`) — design idempotency in before any side-effecting consumer; flag-off default = zero behavior change.

## [2026-06-18] Slice: Kafka step 3 (i) — brod-backed PRODUCER adapter (message.created.v1 reaches a real broker)
- Status: ✅ green (incl. a live-broker integration test)
- Files changed: new `apps/shared_infra/lib/shared_infra/kafka/brod_producer.ex` (`BrodProducer`); `apps/shared_infra/mix.exs` (+`{:jason, "~> 1.4"}` — already locked, declared for compile scope); `apps/shared_infra/test/test_helper.exs` (+`kafka_integration` exclude, FIRST); `apps/message_service/lib/message_service/messages.ex` (wrapped publish in `Task.start`, split out `do_publish_message_created/1`); `apps/message_service/lib/message_service/application.ex` (flag-gated supervised brod client child; was `children=[]`); `config/config.exs` (`KAFKA_PRODUCER_ADAPTER` env → brod|Noop, default Noop unchanged); `apps/message_service/test/.../message_created_event_test.exs` (capture adapter sends to configured test pid + `assert_receive`, for the Task process change); new `apps/shared_infra/test/shared_infra/kafka_brod_producer_integration_test.exs` (`@tag :kafka_integration`); `infra/docker/docker-compose.yml` (one-shot `kafka-init` running `create-topics.sh`); docs.
- Event-flow behavior: after a successful persist, `message.created.v1` is published fire-and-forget via the `Producer` boundary. Default `NoopProducer` (no-op). With `KAFKA_PRODUCER_ADAPTER=brod`, `BrodProducer` JSON-encodes the envelope (jason; `encode/1`, errors logged + `{:error,_}`, never raised) and **async** `:brod.produce(client, topic, :hash, conversation_id, encoded)`; the brod client is started ONLY when the brod adapter is selected, in `MessageService.Application` (`application.ex` `brod_producer_selected?`/`brod_client_child_spec`) — default off → no client → Docker-free. Emit wrapped in `Task.start` so create latency is fully decoupled from the broker. Topic `message.events.v1` created with 6 partitions by the new `kafka-init`.
- Config/env flags: `KAFKA_PUBLISH_ENABLED` (emit gate, default off), `KAFKA_PRODUCER_ADAPTER` (`brod`→BrodProducer, default NoopProducer), brokers from `KAFKA_BROKERS` (default localhost:9094).
- Verification: mix format clean; mix compile --warnings-as-errors clean (after declaring jason for shared_infra — the only hiccup, a `Jason.encode` undefined warning since shared_infra hadn't depended on jason); `mix test` → **186 passed / 57 excluded** (passed UNCHANGED → Docker-free intact; +1 excluded = the kafka_integration test); shared_infra alone → 29 passed, 2 excluded (banner shows redis+kafka excluded); `mix test --include postgres_integration` → **241 passed, 0 failures**; **live `mix test --include kafka_integration` → 1 passed** (broker up on :9094; brod client connected, produced to `message.events.v1`, logs confirmed 6 partitions/producers 0–5); the 3 step-2 plain fake-adapter tests still pass (updated for the Task process model). web lint/typecheck/build ok (untouched).
- Two non-negotiables honored: (1) ASYNC produce only + `Task.start` → fire-and-forget for correctness AND latency; (2) brod client started ONLY under the flag in `MessageService.Application` (`application.ex` conditional `children/0`), never unconditionally — default `NoopProducer` → no connect. test_helper exclude added BEFORE the tagged test (twice-burned lesson).
- Caveats: consumer side NOT built (separate slice). `event_id`/`correlation_id` still generated locally (no request-scoped trace id). The brod client name is a fixed atom (`:message_service_kafka_client`); brokers from config.
- Doc corrections: KAFKA_EVENT_CATALOG message.created.v1 marked WIRED-with-real-brod-adapter + partition discrepancy RESOLVED (kafka-init → 6).

## [2026-06-18] Inspection pass: brod-backed producer adapter (Kafka step 3 phase 1, no code/deps changed)
- Status: ℹ️ inspect-only; nothing changed but this note. Phase 2 awaiting approval.
- Findings: producer contract = `@callback produce(topic, key, value, opts) :: {:ok,_}|{:error,_}` (`producer.ex:13`); default `NoopProducer` via `:shared_infra, :kafka_producer_adapter` (`producer.ex:20-26`), set to `NoopProducer` in config.exs. `value` is currently the envelope MAP → a brod adapter must JSON-encode; **jason 1.4.5 is already in the lock** (no new dep). brod is in shared_infra deps and compiles. **shared_infra has NO supervision tree** (`extra_applications: [:logger]`, no `mod:`), so a brod CLIENT must be supervised elsewhere — `MessageService.Application.start/2` currently has `children = []` (`application.ex:8`); that's the flag-gated conditional-child location (mirror the Scylla/Xandra lesson). brod API: `:brod.start_link_client/3` (supervisable, `brod.erl:453`), `:brod.start_producer/3` (`:491`), and produce variants — `produce/5` ASYNC returns `{:ok, call_ref}` (`:624`), `produce_no_ack/5` (`:688`), `produce_sync/5` BLOCKS on ack (`:733`).
- ⚠️ Sync/async (the key risk): the emit point `Messages.publish_message_created/1` is called SYNCHRONOUSLY inline before `{:ok, response}` is returned. Its `try/rescue/catch` protects CORRECTNESS but NOT LATENCY — a `produce_sync` would stall create up to the broker timeout. The brod adapter MUST use ASYNC produce (`:brod.produce/5` / `produce_no_ack/5`), and pre-start the producer (or `auto_start_producers: true`) so there's no synchronous producer-start on the create path; optionally wrap in `Task.start`.
- ⚠️ test_helper exclude: `apps/shared_infra/test/test_helper.exs` excludes only `redis_integration` — **`kafka_integration` must be added there BEFORE any tagged test** (missing-exclude lesson, hit twice already).
- ⚠️ Topic/partition delta: `topics.env` declares `message.events.v1:6:1` (6 partitions), but docker-compose has `AUTO_CREATE_TOPICS=true` + `NUM_PARTITIONS=3` and **no service invokes `create-topics.sh`** (grep of docker-compose found no reference) → on a fresh stack the topic auto-creates with **3** partitions on first produce. Fix in (i): wire a kafka-init one-shot that runs `create-topics.sh`, or reconcile topics.env/catalog to 3.
- Recommended Phase 2(i): `SharedInfra.Kafka.BrodProducer` (Jason-encode + `:brod.produce/5` async, `:hash` partitioner on key=conversation_id) + a flag-gated supervised brod client in `MessageService.Application` (default off → no client → Docker-free) + select adapter via env (default stays NoopProducer) + ONE `@tag :kafka_integration` round-trip test (after adding the exclude) + the topic-init infra fix. Consumer = separate slice (ii).

## [2026-06-18] Slice: Kafka STEP 2 — first event `message.created.v1` (fire-and-forget)
- Status: ✅ green
- Files changed: `apps/message_service/lib/message_service/messages.ex` (+`publish_message_created/1`, `build_message_created_envelope/1`, `kafka_publish_enabled?/0`, aliases, `@message_topic`), `config/config.exs` (`kafka_publish_enabled` flag, default off), new `apps/message_service/test/message_service/message_created_event_test.exs` (+3 plain tests + 2 fake adapters), docs (KAFKA_EVENT_CATALOG, DECISION_LOG, ROADMAP, AI_CONTEXT, CODEMAP).
- Event flow: after a successful `create_message_in_store` persist, `publish_message_created/1` builds a `message.created.v1` envelope (`SharedInfra.Events.Envelope`) and publishes via `SharedInfra.Kafka.Producer.produce/4` to topic `message.events.v1`, key `conversation_id`. FIRE-AND-FORGET: the `{:ok, response}` is computed/returned independently; build/produce are wrapped in `try/rescue/catch` and any error/exception/exit is caught + logged (`Logger.warning`), NEVER propagated. Gated by `KAFKA_PUBLISH_ENABLED` (default off) → no publish, behavior byte-for-byte unchanged. Default producer adapter stays `NoopProducer`; NO brod connection started in this slice.
- Config/env flags: `KAFKA_PUBLISH_ENABLED` (`:message_service, :kafka_publish_enabled`, default false); producer adapter `:shared_infra, :kafka_producer_adapter` (default `NoopProducer`).
- Verification: mix format clean; mix compile --warnings-as-errors clean; event test file → 3 passed; `mix test` → **186 passed / 56 excluded** (was 183/56; +3 PLAIN tests; excluded UNCHANGED → no integration tests leaked, Docker-free intact); `mix test --include postgres_integration` → **241 passed, 0 failures** (was 238; +3; confirmed via per-app breakdown — an earlier piped count showed a spurious 200 because the expected fire-and-forget `[warning] publish raised, ignored` log line interleaved with the grep). web lint/typecheck/build ok (untouched).
- Tests (Docker-free, fake adapters, NO live broker): (1) event emitted after create → fake capturing adapter receives `{topic="message.events.v1", key=conversation_id, envelope}`; asserts envelope validity + payload; (2) publishing disabled → NO emission, create still succeeds; (3) **producer RAISES → create STILL succeeds + message persisted** (fire-and-forget proven; the warning log confirms the exception was caught). No `kafka_integration`-tagged tests added (none needed; envelope/event tests are plain).
- Caveats: value passed to `produce` is the envelope MAP (the live brod adapter will JSON-encode — its concern). `event_id`/`correlation_id` generated locally (no request-scoped trace id threaded yet). Consumer side + live brod-backed adapter still pending.

## [2026-06-18] Slice: Kafka (c) step 1.5 — CI installs cmake/toolchain for the brod NIF (CI-config only)
- Status: ✅ green locally (no code touched); real proof = next CI run.
- Files changed: `.github/workflows/backend-ci.yml` only — added an "Install build toolchain (cmake for brod/crc32cer NIF)" step (`sudo apt-get update && sudo apt-get install -y --no-install-recommends cmake build-essential`) after `setup-beam`, before the cache/`deps.get`/`compile` steps (lines 31-32). Docs (DECISION_LOG, AI_CONTEXT).
- Behavior: NONE (CI config only). No application code, deps, config, or tests changed.
- Inspection: runner is `ubuntu-latest`; step order checkout → setup-beam → cache → deps.get → format → compile → test. Ubuntu images ship build-essential (and usually cmake), but cmake is installed explicitly to guarantee the `crc32cer` NIF builds; the cache key is `mix.lock`-hashed (changed when brod was added → cache miss → fresh dep compile → NIF build needs the toolchain).
- Verification: CI-config slice — cannot be fully verified locally. YAML re-read end-to-end: well-formed, correct indentation, all existing steps intact and in order, new step placed before any compilation. Local `mix test` unaffected (no code touched) — still 183 passed / 56 excluded. **Final proof = the next CI run must show brod/crc32cer compiling green.**
- Closes the owed CI follow-up flagged in step 1.

## [2026-06-18] Slice: Kafka (c) step 1 — re-add brod, prove it compiles (cmake now present), no wiring
- Status: ✅ green (brod present but unused; behavior unchanged)
- Files changed: `apps/shared_infra/mix.exs` (re-added `{:brod, "~> 4.0"}`), `mix.lock` (brod 4.5.5 / kafka_protocol 4.3.4 / crc32cer 1.1.3 back), docs (DECISION_LOG, AI_CONTEXT).
- Step 0: `cmake --version` → 4.3.3 at /opt/homebrew/bin/cmake (the blocker from (a)+(b) is resolved).
- Behavior: NONE changed. brod is a present-but-unused dependency. `SharedInfra.Kafka.Producer` dispatcher still defaults to `NoopProducer` (config.exs unchanged); no brod connection started anywhere (no `Application.start` change); flag-off = no connect = Docker-free. No producer hook, consumer, or topic wiring (that's step 2).
- Verification: `cmake --version` present; `mix deps.get` (brod 4.5.5/kafka_protocol 4.3.4/crc32cer 1.1.3); `mix compile --warnings-as-errors` → CLEAN exit 0 (crc32cer NIF builds via cmake). brod's own Erlang source emits deprecation warnings (`brod_supervisor3.erl` legacy `catch`) during dep compile, but those do NOT fail `--warnings-as-errors` (it governs our Elixir modules; deps compile separately) — build passes. `mix test` → **183 passed / 56 excluded** (UNCHANGED — brod present but unused). `mix test --include postgres_integration` → **238 passed**, 0 failures. web lint/typecheck/build ok (untouched).
- Guards: (1) compile clean with brod (exit 0); brod's deprecation warnings are dep-side, not warnings-as-errors failures — reported, flag NOT weakened. (2) default adapter still `NoopProducer`; nothing connects. (3) no integration-tagged tests added. (4) mix.lock has brod/kafka_protocol/crc32cer.
- ⚠️ CI follow-up (owed, NOT done here — scope was compile-proof only): `.github/workflows/backend-ci.yml` must install a C toolchain + cmake before `mix compile`, or CI will fail building the `crc32cer` NIF (same failure we hit locally before cmake). Tracked in DECISION_LOG.

## [2026-06-18] Slice: Kafka (a) producer dispatcher + NoopProducer default, (b) event envelope contract — dormant scaffolding
- Status: ✅ green (behavior unchanged; dormant scaffolding)
- Files changed: `apps/shared_infra/lib/shared_infra/kafka/producer.ex` (added dispatcher + `NoopProducer`), new `apps/shared_infra/lib/shared_infra/events/envelope.ex`, `config/config.exs` (`kafka_producer_adapter: NoopProducer` default), new tests `apps/shared_infra/test/shared_infra/events_envelope_test.exs` + `kafka_producer_test.exs`, docs (KAFKA_EVENT_CATALOG, DECISION_LOG, AI_CONTEXT, CODEMAP).
- Step 0 (Xandra lesson): added `{:brod, "~> 4.0"}`, `mix deps.get` RESOLVED cleanly (decimal 3.1.1 / ecto 3.14.0 unchanged — brod is decimal-free). BUT brod **fails to compile** here: transitive NIF `crc32cer` needs `cmake` (`make: cmake: No such file`). Since (a)+(b) need no broker driver, REVERTED the brod dep (`mix deps.unlock --unused` removed brod/kafka_protocol/crc32cer from the lock) and landed (a)+(b) brod-free. brod is deferred to slice (c), gated on the NIF/cmake blocker (did NOT install system toolchain or hack overrides).
- Behavior: `SharedInfra.Kafka.Producer` now dispatches to a configured adapter (default `NoopProducer` → `{:error, :kafka_unavailable}`, no connection), mirroring `Scylla.Client`. `SharedInfra.Events.Envelope.build/1` + `validate/1` enforce the documented standard envelope (required event_id/event_type/event_version(int)/producer/occurred_at/correlation_id/payload(map); optional tenant_id/actor_user_id; pure functions). DORMANT — no producer hook, no consumer, nothing connects.
- Verification: mix format clean; mix compile --warnings-as-errors clean; plain `mix test` → **183 passed / 56 excluded** (was 174/56; +9 PLAIN envelope/producer tests; excluded UNCHANGED → no integration tests added, Docker-free intact); `mix test --include postgres_integration` → **238 passed** (was 229; +9); shared_infra 20→29. web lint/typecheck/build ok (untouched). (One self-inflicted test bug — a validate test reused a fixture lacking event_version → fixed the fixture, not the code.)
- Guards: (1) NO brod connection started anywhere (no Application.start change; brod not even installed) → nothing connects, Docker-free. (2) Defaults unchanged elsewhere. (3) No integration tests added (envelope/producer tests are plain). (4) mix.lock cleaned (no brod entries).
- Doc corrections: KAFKA_EVENT_CATALOG now carries an Implementation-Status banner (it was a spec presented as a catalog — `producer:` fields name intended, not existing, producers) + flags the `message.events.v1` 6-vs-3 partition discrepancy.

## [2026-06-18] Inspection pass: Kafka event flow (Phase 1, no code/deps changed)
- Status: ℹ️ inspect-only; nothing changed except this note. Phase 2 awaiting approval.
- Findings (code-verified): Kafka is 0% wired — `SharedInfra.Kafka.Producer`/`Consumer` are `@callback` behaviours ONLY (producer.ex:9, consumer.ex:9-11); only test adapters exist; the sole "usages" are dead `kafka_config/0` accessors in `message_service`/`realtime_gateway` `infrastructure.ex:10` (never called). CRITICAL structural gap vs Scylla: there is NO dispatcher + NO safe-default adapter (no `SharedInfra.Kafka.Producer.produce/4` function, no `UnavailableProducer`) — unlike `SharedInfra.Scylla.Client` which had `adapter()` + `UnavailableClient`. Config: `config :message_service/:realtime_gateway, :kafka` (brokers/client_id from `KAFKA_BROKERS`/`KAFKA_CLIENT_ID`); no adapter/flag selection. Infra: docker-compose Kafka (KRaft, :9094, AUTO_CREATE_TOPICS=true, NUM_PARTITIONS=3); `topics.env` lists 11 `*.events.v1` topics (message=6 partitions, rest 3); `create-topics.sh` creates them. Catalog (`KAFKA_EVENT_CATALOG.md`) documents the same 11 topics + ~40 event types + standard envelope, each with a "producer: <service>" that does NOT exist in code → catalog reads as spec but presents as catalog (all events 🔴 documented-only).
- Dependency-conflict check (the Xandra lesson, done BEFORE adopting): lock pins `decimal 3.1.1`, `ecto 3.14.0`. **brod** (Erlang) deps = kafka_protocol/crc32cer/snappyer/supervisor3 — NONE depend on `decimal` or `ecto` → no conflict expected (brod is decimal-free, unlike Xandra). kafka_ex similar. broadway_kafka adds broadway (gen_stage/telemetry ~>1.0/nimble_options) — telemetry 1.4.2 satisfies, but more surface. Recommend **brod** for the thin slice; still run `mix deps.get` resolution check as Phase 2 step 0 before any code.
- Recommended phasing: (a) add brod behind a flag-gated, NON-connecting default + a `SharedInfra.Kafka.Producer` dispatcher with a safe `NoopProducer`/`UnavailableProducer` default (mirror `Scylla.Client`) — zero behavior change; (b) central event envelope/contract module in shared_infra (build+validate the documented envelope) BEFORE multiple producers; (c) THIN VERTICAL SLICE — produce `message.created.v1` on successful persist + one minimal consumer, `kafka_integration`-tagged round-trip test (excluded by default → Docker-free); (d) wire/ document topic creation + expand. Rule-conflicts to NOT do blind: never start a brod connection in `Application.start` unconditionally (flag-gate it); add `ExUnit.configure(exclude: [kafka_integration: true])` to test_helpers BEFORE the tagged tests (the realtime/message_service missing-exclude lesson); the producer hook must be best-effort and MUST NOT fail message creation if the broker is down. Doc fix owed: annotate KAFKA_EVENT_CATALOG with real implementation status + reconcile message.events.v1 partition count (6 in topics.env vs 3 from AUTO_CREATE).

## [2026-06-18] Slice: Postgres-backed message store adapter (real durability now)
- Status: ✅ green
- Files changed: `apps/message_service/mix.exs` (+ecto_sql/postgrex, elixirc_paths), new `apps/message_service/lib/message_service/repo.ex`, `schemas/message.ex`, `schemas/message_receipt.ex`, `message_store.ex` (+`PostgresAdapter`), `config/config.exs` (ecto_repos + `MESSAGE_STORE_ADAPTER=postgres`), `config/dev.exs` + `config/test.exs` (MessageService.Repo), new `infra/docker/postgres/init/020_message_store.sql`, new `test/support/data_case.ex`, new `test/message_service/postgres_message_store_test.exs`, `test/test_helper.exs` (+postgres_integration exclude), docs (DECISION_LOG, ROADMAP, PROJECT_STATUS, AI_CONTEXT, CODEMAP).
- Behavior: New `MessageService.MessageStore.PostgresAdapter` implements all 7 MessageStore callbacks against `MessageService.Repo` (new `messages`/`message_receipts` tables, NO cross-service FKs → single self-contained repo), returning the same atom-keyed shapes as the other adapters. Selected via the existing `MESSAGE_STORE_ADAPTER=postgres`; defaults UNCHANGED (QueryPlan/in-memory) so plain `mix test` stays Docker-free. Media metadata (object_key/filename/content_type/size_bytes/caption) round-trips through jsonb. Authz (author-only edit/delete, membership) stays above the store — adapter is storage-only. Cross-day `bucket_date` issue does NOT apply (PG has no partitions; lookups by message_id/conversation_id).
- Verification: mix format clean; mix compile --warnings-as-errors clean; plain `mix test` → **174 passed / 56 excluded** (passed UNCHANGED vs baseline 174 → Docker-free intact; +4 excluded = 4 new pg-integration tests); message_service alone → 34 passed, 4 excluded (new tests excluded by default — added the missing `ExUnit.configure(exclude: postgres_integration)` to message_service test_helper, same gap previously found in realtime_gateway); `mix test --include postgres_integration` → **229 passed** (was 225; +4: create→list, edit+delete, non-author reject, media-metadata round-trip); web lint/typecheck/build ok (untouched). NOTE: applied `020_message_store.sql` to the local `chat_platform_test` DB so the pg tests can run (operators must apply it; CI runs plain test only).
- Rule #10: the new pg tests touch ONLY `MessageService.Repo` (single repo; no cross-repo FK rows) → no sandbox lock. The `messages` table has no FKs to users_auth/conversations by design.
- Decision recorded (DECISION_LOG 2026-06-18): durability on Postgres now; ScyllaDB high-write backend deferred to Phase 8 (ecto/decimal conflict), kept swappable behind the adapter boundary.
- Doc corrections: PROJECT_STATUS finding #2 / §data updated from ⚠️ "no live persistence" to ✅ resolved-via-Postgres; ROADMAP adds Phase 8 (Scylla live backend + Kafka) as explicit future milestones rather than silent gaps.

## [2026-06-18] Slice: live Scylla persistence sub-slice (a) — BLOCKED (dependency conflict), reverted
- Status: 🔴 blocked — no net change (edits reverted; tree back to baseline).
- What happened: attempted to add `{:xandra, "~> 0.18}` to `apps/message_service/mix.exs` + a flag-gated Xandra child in `MessageService.Application`. `mix deps.get` FAILED resolution: `ecto 3.14.0` requires `decimal ~> 3.0`, but every `xandra >= 0.15` requires `decimal ~> 1.7 or ~> 2.0` — disjoint, so Xandra cannot be added alongside the current Ecto/decimal. `mix.lock` was not written (resolution failed first; verified 0 xandra entries).
- Reverted both edits; confirmed restored: `mix compile --warnings-as-errors` clean, plain `mix test` 174 passed / 52 excluded (baseline; note 52 not 50 — the prior membership slice added 2 pg-integration tests). No deps, no behavior change landed.
- Decision needed (architectural — sub-slice (a) cannot proceed as scoped): options —
  (A) downgrade Ecto to a version allowing `decimal ~> 2.0` (own slice; full Postgres-services regression) then Xandra fits;
  (B) use an Erlang CQL driver with no Elixir `decimal` dep (e.g. cqerl) as the live client backend — sidesteps the conflict, less idiomatic/maintained;
  (C) defer until a Xandra release supports `decimal ~> 3.0` (none on hex today);
  (D) reconsider the store: a Postgres-backed message store adapter (the `MessageStore` boundary already supports swapping) avoids the CQL driver + decimal issue entirely, at the cost of the ScyllaDB design for now.
- Did NOT hack around it (no `decimal` override — impossible vs ecto's `~> 3.0`; no blind Ecto downgrade). Awaiting direction.

## [2026-06-18] Inspection pass: live Scylla message persistence (Phase 1, no code/deps changed)
- Status: ℹ️ inspect-only; nothing changed except this note. Phase 2 awaiting approval (likely just sub-slice (a): add Xandra dep + flag-gated connection, no behavior change).
- Findings (code-verified): `MessageService.MessageStore.ScyllaAdapter` already builds real CQL via `MessageService.Persistence.*` query plans and calls `execute(client, plan)` → `client.execute(stmt, params, scylla_config)`; `client_adapter` defaults to `SharedInfra.Scylla.Client` (`message_store.ex:112`), which dispatches to `:shared_infra, :scylla_client_adapter` = `UnavailableClient` (`config.exs:79-80`) → `{:error, :scylla_unavailable}` → mapped to `:message_store_unavailable`. **No Cassandra/Scylla driver in mix.lock; nothing connects.** The clean live seam = ONE module implementing the 2-callback `SharedInfra.Scylla.Client` behaviour (`prepare/2`, `execute/3`); query plans are already written. Adapter selection: `MESSAGE_STORE_ADAPTER` (config.exs:70-77) → scylla/in_memory/QueryPlan(default); default test/dev/plain = QueryPlan + UnavailableClient (offline). `MessageService.Application` starts NO children (empty supervisor). CQL schema partition key is `((conversation_id, bucket_date), message_id)` with timeuuid `message_id` — so the cross-day `bucket_date` miss is INHERENT to the live partitioning (edit/delete/get compute bucket_date from now → wrong partition for prior-day messages). pg-integration pattern (`config/test.exs` Sandbox + `@tag :postgres_integration` excluded by default) is the template for a future `scylla_integration` tag.
- Assessment: realistic driver = **Xandra** (pure-Elixir Cassandra/Scylla CQL driver). Adding the dep does NOT connect by itself; Docker-free is preserved IFF the Xandra connection is started ONLY behind a flag (never unconditionally in `Application.start`) and defaults (`UnavailableClient`/`QueryPlanAdapter`) stay. Param encoding (uuid/timeuuid/date/timestamp/map<text,text>) is the main correctness risk for the live client. Recommended phasing: (a) add Xandra dep + flag-gated supervised connection, zero behavior change [Phase 2, LOW risk]; (b) implement `SharedInfra.Scylla.XandraClient` (prepare/execute + type encoding) behind config [MEDIUM]; land the cross-day `bucket_date`-from-timeuuid fix as part of/before this; (c) `scylla_integration`-tagged tests vs a real node, excluded by default [MEDIUM]; (d) docker-compose Scylla + CQL init + Makefile + docs for local/integration only [LOW]. Do NOT: start the connection unconditionally, or flip default adapters — either would force Docker into plain `mix test`.

## [2026-06-18] Slice: HTTP message create/list — conversation membership enforcement (privacy fix)
- Status: ✅ green
- Files changed: `apps/backend/apps/api_gateway/lib/api_gateway_web/controllers/message_controller.ex` (+ `authorize_membership/2` wired into `create_message_from_store` + `list_messages_from_store`), `apps/backend/apps/api_gateway/test/api_gateway_web/controllers/message_controller_membership_postgres_integration_test.exs` (new, +2 tests), docs (SECURITY_MODEL, AI_CONTEXT, ROADMAP, PROJECT_STATUS).
- Behavior: HTTP message create + list now call `ConversationService.Conversations.get_conversation(%{"conversation_id"=>id, "user_id"=>session.user_id})` — the SAME membership check the realtime channel-join path uses — before proceeding. A non-participant gets `403 message.forbidden` (reuses the existing `ErrorResponse.forbidden/3`; no new envelope). Closes the audit's 🔴 HIGH finding that any authenticated user could POST to / read any conversation over REST. WS path untouched (already join-gated); `message_service` untouched (no new cross-app dep). Flag-off behavior unchanged: with `CONVERSATION_DB_BACKED` off, `get_conversation` returns a placeholder `{:ok}` so the Docker-free path still works.
- Verification: mix test → **174 passed / 50 excluded** (UNCHANGED — the membership check doesn't break the Docker-free path; media create still 201, proving the allow-path wiring flag-off); mix test --include postgres_integration → **225 passed** (was 223; +2 negative membership tests); membership test file → 2 passed; mix compile --warnings-as-errors clean; web lint/typecheck/build ok (web untouched).
- Tests + hard rule #10: added 2 `postgres_integration` NEGATIVE tests (non-participant create → 403; non-participant list → 403). They use a requester (AuthRepo session user) that is a DIFFERENT row from the seeded conversation member (ConversationRepo, FK to users_auth) — different rows across repos, so no cross-repo same-FK-row sandbox lock. The POSITIVE "member allowed" HTTP path is deliberately NOT a DB test (it would need the same user row in both AuthRepo and ConversationRepo = the #10 hazard); its wiring is covered Docker-free by the media create test (conversation-off → placeholder {:ok} → 201) and get_conversation's positive participant path by conversation_service's own pg tests.
- Caveats / follow-ups (NOT fixed): block-state and tenant authz for messaging, and the `MessageService.Permissions.authorize/1` / `ConversationService.Permissions.authorize/1` placeholders, remain open; cross-day `bucket_date` partition miss tracked.
- Doc corrections: PROJECT_STATUS.md finding #1 (HTTP create/list no membership) updated from 🔴 open to resolved for create/list.

## [2026-06-18] Slice: socket auth fail-closed guard (Phase 2)
- Status: ✅ green
- Files changed: `apps/backend/apps/auth_service/lib/auth_service/sessions.ex` (+ public `persistence_enabled?/0`), `apps/backend/apps/realtime_gateway/lib/realtime_gateway/user_socket.ex` (`require_db_backed_sessions` guard), `apps/backend/apps/realtime_gateway/test/realtime_gateway/channels_test.exs` (+3 tests, +session_persistence save/restore), `apps/backend/apps/realtime_gateway/test/test_helper.exs` (added `exclude: postgres_integration`), `apps/backend/config/config.exs` (misconfig comment), docs (SECURITY_MODEL.md, AI_CONTEXT.md).
- Behavior: `RealtimeGateway.UserSocket.authenticated_connect` now first requires `AuthService.Sessions.persistence_enabled?()`; when socket auth is ON but `AUTH_SESSION_DB_BACKED` is OFF, the connection is REJECTED instead of accepting the unverified placeholder identity (closes the partial-on foot-gun from the Phase 1 inspection). Clean distinguisher: a new public predicate on `AuthService.Sessions` (no string-sentinel hack). OFF (placeholder) default path unchanged. The fully-on path already validates tokens identically to HTTP (same `current_session/1`).
- Verification: mix test → **174 passed / 48 excluded** (baseline 173; +1 Docker-free foot-gun test; realtime now "22 passed, 2 excluded"); mix test --include postgres_integration → **223 passed** (baseline 220; +1 foot-gun +2 socket integration tests); mix compile --warnings-as-errors clean; web lint/typecheck/build ok (web untouched).
- Tests added: (1) Docker-free foot-gun regression — socket auth ON + session layer OFF → `:error`; (2) `@tag :postgres_integration` — valid DB-backed session token → `{:ok}` with the REAL verified `user_id` (seeded users_auth + device_sessions, token via `AuthService.Tokens.prepare_issue_pair`); (3) `@tag :postgres_integration` — tampered token → `:error`. Existing OFF→placeholder and ON+no-token→`:error` still pass.
- Doc corrections: discovered + fixed that `apps/realtime_gateway/test/test_helper.exs` lacked `ExUnit.configure(exclude: [postgres_integration: true])`. Consequence: running the realtime app's tests in isolation (or the protocol's targeted multi-path command) would RUN the new integration tests against a real DB instead of skipping them — only passing because a local Postgres exists, silently breaking the Docker-free guarantee. Added the exclude so realtime integration tests are skipped by default everywhere and only run with `--include postgres_integration`.
- Caveats / follow-ups (explicitly NOT done, per scope): flag-default flip to ON (breaks Docker-free dev/tests — deployment decision); true JWT signing + key rotation (tokens are a custom HMAC signed-envelope); channel-join authz hardening; broader edit/delete authz; cross-day `bucket_date` fix.

## [2026-06-18] Inspection pass: socket auth hardening (Phase 1, no code change)
- Status: ℹ️ inspect-only; no code/docs behavior changed (this SESSION_LOG note aside). Phase 2 awaiting approval.
- Findings (code-verified): `RealtimeGateway.UserSocket.connect/3` (`user_socket.ex:9-15`) branches on `socket_auth_persistence_enabled?` (`:realtime_gateway,:socket_auth_persistence` / `REALTIME_AUTH_DB_BACKED`, default OFF — `config.exs:106`). OFF (default) = `placeholder_connect` trusts a client-provided `user_id` param (`user_socket.ex:30-37`) → unauthenticated impersonation possible. ON = `authenticated_connect` requires a token and calls `AuthService.Sessions.current_session` (reject on failure). That validator has its OWN gate `session_persistence_enabled?` (`AUTH_SESSION_DB_BACKED`, default OFF, not set in config/): if OFF it returns a placeholder session (user_placeholder) WITHOUT verifying the token (`sessions.ex:23-29`); only with BOTH flags on + Repo started does it do full validation — signature + expiry (`tokens.ex verify_signed_token`), claims, issuer/audience, active non-revoked device session, active user — identical to the HTTP bearer path. Tests cover only OFF→placeholder and ON+no-token→:error (`channels_test.exs:46-58`); the authenticated happy path is untested. Web sends `authorization: "Bearer <token>"` on connect (`realtime.ts:38-43`).
- Assessment: OFF default is a real hole if prod runs OFF (raw client can claim any user_id; combined with channel-driven create + author-only edit/delete, that's impersonation). Enabling only `REALTIME_AUTH_DB_BACKED` without `AUTH_SESSION_DB_BACKED` is a foot-gun (token unverified → fixed placeholder identity). The token-validation logic already EXISTS and is correct — category (a) trivial wiring/guard/test, NOT a JWT rewrite. Recommended Phase 2: a small fail-closed guard (reject when socket auth is on but session persistence isn't) + authenticated happy-path/tamper tests. Out-of-scope larger items (do NOT do blind): flipping flag defaults to ON (breaks Docker-free dev/tests), true JWT/key rotation (tokens are a custom HMAC signed-envelope), channel-join authz.
- Status: ✅ green
- Files changed: `apps/web/src/lib/realtime.ts`, `apps/web/src/app/chat/page.tsx`, docs (realtime-gateway.md, ROADMAP.md, AI_CONTEXT.md). WEB-ONLY — no backend change (the channel `message:create` handler already persists + broadcasts and returns metadata; confirmed `conversation_channel.ex:82-104` + existing channel media test).
- Behavior: Added a `sendCreate/1` helper in the chat page — when the conversation socket is connected it pushes `message:create` over the channel (for BOTH text and media, including media `metadata`) and inserts the new message from the channel reply; otherwise it falls back to HTTP `createMessage`. Other clients now receive new messages live via the existing `message_created` subscription (the sender is excluded by `broadcast_from`, so it relies on the reply). `mergeMessage` dedupes by `message_id`, so reply-insert + any echo never double-append. Extended `realtime.ts` `sendMessage` payload type with optional `metadata`. HTTP create path retained as fallback.
- Verification: mix test → **173 passed / 48 excluded** (unchanged — backend untouched; existing `message:create` broadcast test still passes); mix test --include postgres_integration → **220 passed**; mix compile --warnings-as-errors clean; web lint → 0 problems; typecheck → ok; build → ok.
- Manual-check note (no web test framework): with two browsers in the same conversation and the backend running with `MESSAGE_DB_BACKED` (+ a live message store) and sockets connected, sending a text or media message in one client should make it appear in the other without reload; media bubbles should show "Open media"/image preview immediately because `metadata.object_key` rides the `message_created` payload.
- Caveats / follow-ups (carry-over, NOT changed here): channel sender identity is only trustworthy when `REALTIME_AUTH_DB_BACKED` is on (same pre-existing socket-auth caveat as edit/delete; this slice does not widen it). Cross-day `bucket_date` partition miss and broader edit/delete authz remain open. If the channel push fails while connected, the error surfaces (no silent HTTP retry) — fallback is only for the disconnected case.
- Doc corrections: none.

## [2026-06-18] Slice: author-only enforcement for message edit + delete (security fix)
- Status: ✅ green
- Files changed: `apps/backend/apps/message_service/lib/message_service/message_store.ex`, `apps/backend/apps/message_service/lib/message_service/messages.ex`, `apps/backend/apps/realtime_gateway/lib/realtime_gateway/conversation_channel.ex`, `apps/backend/apps/api_gateway/lib/api_gateway_web/controllers/error_response.ex`, `apps/backend/apps/api_gateway/lib/api_gateway_web/controllers/message_controller.ex`, plus tests (`message_store_boundary_test.exs`, `message_controller_media_test.exs`, `channels_test.exs`) and docs (SECURITY_MODEL.md, message-service contract via realtime-gateway.md, ROADMAP.md, AI_CONTEXT.md).
- Behavior: Added `MessageStore.get_message/1` (InMemory → `find_message`; QueryPlan → unavailable; Scylla → `list_recent_plan` + filter so the existing `TestScyllaClient` update/delete tests stay green). `MessageService.Messages.update_message`/`delete_message` now call a single `authorize_author/4` at the shared boundary: it fetches the stored message and rejects a non-author with `{:error, :message_forbidden}`. One enforcement point covers BOTH transports: HTTP PATCH/DELETE map it to the documented `403 message.forbidden` (added `ErrorResponse.forbidden/3`); the realtime channel maps it to the existing `realtime.forbidden`. Author (sender) edit/delete still succeeds. Placeholder behavior (MESSAGE_DB_BACKED off) unchanged; success shapes unchanged; edit stays text-only.
- Verification: mix test → **173 passed / 48 excluded** (baseline 169; +4: message_service 32→34, realtime_gateway 20→21, api_gateway 38→39); mix test --include postgres_integration → **220 passed** (baseline 216); mix compile --warnings-as-errors clean; web lint → 0 problems; typecheck → ok; build → ok (web untouched). New tests: boundary author-can / non-author-forbidden for edit+delete; one HTTP non-author (403 message.forbidden); one channel non-author (realtime.forbidden).
- Caveats / follow-ups: (1) Broader edit/delete authz (participant/tenant/block) still TODO — `MessageService.Permissions.authorize/1` remains a placeholder. (2) Channel socket-auth is opt-in: the channel trusts `socket.assigns.current_user_id`, only a real identity when `REALTIME_AUTH_DB_BACKED` is on — recorded as a follow-up, not expanded here. (3) The author fetch shares the known cross-day `bucket_date` partition limitation (prior-day messages); tracked separately.
- Doc corrections: the message-service contract already documented `message.forbidden | 403` but no code emitted it (the existing `:conversation_forbidden` maps to `invalid_request`/400). This slice makes the new author-forbidden path emit the documented `403 message.forbidden`, aligning code with the contract; SECURITY_MODEL.md "Message Authorization" now documents author-only edit/delete as implemented.

## [2026-06-18] Gate reconciliation (no code slice — Gate 0 STOP)
- Status: ⚠️ reconciliation only; the planned "create over channel" slice was NOT started (Gate 0 STOP honored).
- Gate 0 (test-count reconciliation): Root `mix test` runs ALL 8 umbrella apps, but each app is a SEPARATE ExUnit run printing its own `Result:` line; `api_gateway` (depends on every other app) runs LAST. Prior log lines that read "mix test → 38 passed/35 excluded" captured ONLY api_gateway's final line, not the aggregate. TRUE aggregates (verified 2026-06-18):
  - `mix test` → **169 passed, 48 excluded** across 8 apps (media 9 · conversation 14/8 · shared_infra 20/1 · message 32 · auth 24/1 · realtime_gateway 20 · user 12/3 · api_gateway 38/35).
  - `mix test --include postgres_integration` → **216 passed** across 8 apps (prior "73 passed" was api_gateway-only).
  - The 3 realtime edit/delete-broadcast tests DO run and pass (realtime_gateway 17→20). CI exit code aggregates all apps, so the full suite was always actually tested; only the human-readable numbers reported here were partial.
- Gate 1A (known-issue, NOT fixed): cross-day edit/delete partition miss — `update_message_in_store`/`delete_message_in_store` compute `bucket_date` from now (`messages.ex:128-156`), so editing a prior-day message misses its `(conversation_id, bucket_date, message_id)` partition (`message_store.ex:347-359`). `bucket_date` is derivable from the v1 timeuuid `message_id`. Recorded in AI_CONTEXT known-issues.
- Gate 1B (authz, NOT fixed — own slice): channel `message:update`/`message:delete` and HTTP PATCH/DELETE share the SAME `MessageService.Messages.update_message`/`delete_message` boundary, which does NOT enforce author-only edit/delete (`messages.ex:121-163`; `Permissions.authorize/1` is placeholder). No new gap from the channel (symmetric, pre-existing). Separate asymmetry: HTTP requires a valid bearer session; the channel uses socket identity (only authenticated when `REALTIME_AUTH_DB_BACKED` is on). Not a one-line fix → flagged as its own slice.
- Doc corrections: prior SESSION_LOG verification lines reading "mix test → 38 passed/35 excluded" and "postgres → 73 passed" were the api_gateway-only per-app lines, not aggregates; the true full-suite numbers are 169 passed/48 excluded and 216 passed respectively. The most recent (edit/delete realtime) entry's Verification line is corrected below.

## [2026-06-18] Slice: realtime propagation of message edit/delete
- Status: ✅ green
- Files changed: `apps/backend/apps/realtime_gateway/lib/realtime_gateway/conversation_channel.ex`, `apps/backend/apps/realtime_gateway/test/realtime_gateway/channels_test.exs`, `apps/web/src/lib/realtime.ts`, `apps/web/src/app/chat/page.tsx`, `docs/05-api-contracts/realtime-gateway.md`, `docs/03-roadmap/ROADMAP.md`
- Behavior: Added `message:update` / `message:delete` channel events to `ConversationChannel`, mirroring the existing `message:create` handler exactly — actor derived from `socket.assigns`, call `MessageService.Messages.update_message`/`delete_message`, then `broadcast_from(socket, "message_updated"/"message_deleted", response)` and reply to sender. Web now edits/deletes over the channel when connected (HTTP `editMessage`/`deleteMessage` kept as fallback) and subscribes to `message_updated`/`message_deleted`, patching local `messages` by `message_id` (idempotent). Other connected clients now see edits/deletes live. Placeholder behavior (MESSAGE_DB_BACKED off) unchanged; no error-envelope changes.
- Verification: mix test → full umbrella **169 passed / 48 excluded** across 8 apps (realtime_gateway 17→20 incl. the 3 new tests; api_gateway 38/35); mix test --include postgres_integration → **216 passed**; mix compile --warnings-as-errors clean; web lint → 0 problems; web typecheck → ok; web build → ok. [corrected 2026-06-18: this line originally read "38 passed/35 excluded" and "73 passed" — those were only api_gateway's per-app Result lines, not the aggregate; see the Gate reconciliation entry above.]
- Caveats / follow-ups: (1) The `message_updated`/`message_deleted` broadcasts use `broadcast_from`, so the acting client is excluded and relies on its own patch (idempotent) — no flicker/dupe. (2) Known asymmetry NOT addressed here: message **creation** in the web still uses HTTP `createMessage` and never pushes `message:create`, so the existing `message_created` broadcast remains dormant for new messages in the real web flow — bringing create onto the channel is a separate slice. (3) For DB-backed edit/delete via the in-memory/Scylla store, the message must be found by `(conversation_id, bucket_date, message_id)`; same-day edits match, but editing a message from a previous day misses its partition — pre-existing behavior, not introduced here.
- Doc corrections: `docs/05-api-contracts/realtime-gateway.md` already listed `message_updated`/`message_deleted` as server events but they were unimplemented; they are now real, and the matching `message:update`/`message:delete` client events were added to the contract.

## [2026-06-18] Slice: image preview for media messages (no-op — already implemented) + carry-over fixes
- Status: ✅ green
- Files changed: `docs/03-roadmap/ROADMAP.md` only (no production code changed)
- Behavior: No new feature code. The requested inline image preview already exists and meets every requirement — verified in `apps/web/src/app/chat/page.tsx:898-967` (`MediaMessageContent`): `isImage` derived from `metadata.content_type` (`:902`), inline `<img>` with `max-h-64 w-full rounded-md object-cover` + `loading="lazy"` + `onError` fallback (`:948-954`), download URL resolved once via `getMediaDownloadUrl` (`:918`) and shared into `OpenMediaLink` as `prefetchedUrl` so it is not fetched twice (`:962`), and the non-image / missing-`object_key` fallback (`:935`, `:958`). Re-implementing was intentionally avoided per the no-rewrite / small-diff rules.
- Carry-over A (ROADMAP): Added a Phase 4 line marking "Message edit/delete UI (web)" done EXCEPT realtime propagation.
- Carry-over B (regression check): CONFIRMED no regression. `MessageBubble` (rewritten in the edit/delete slice) still delegates media to `<MediaMessageContent>` (`apps/web/src/app/chat/page.tsx:858-859`); the "Open media" link still renders from `metadata.object_key` via `canResolve` (`:903`, `:958-964`). Media rendering survived intact.
- Verification: mix test → 38 passed/35 excluded (backend untouched); mix test --include postgres_integration → 73 passed; web lint → 0 problems; web typecheck → ok; web build → ok.
- Caveats / follow-ups: Image preview only appears for messages that carry `metadata.object_key` + image `content_type` (i.e. created with `MESSAGE_DB_BACKED` on, per earlier slices). Video/file inline rendering still not in scope.
- Doc corrections: This slice's instructions asked to implement image preview as if pending, but it was already delivered in the earlier image-preview slice; recorded here as a no-op to keep the log truthful.

## [2026-06-18] Slice: message edit/delete UI
- Status: ✅ green
- Files changed: `apps/web/src/lib/api.ts`, `apps/web/src/app/chat/page.tsx`
- Behavior: Added web `editMessage` (PATCH) and `deleteMessage` (DELETE) API client functions for the existing message endpoints. Chat bubbles for the current user's own, non-deleted messages now show inline **Edit** (text messages only) and **Delete** controls; Edit opens an inline input with Save/Cancel and a busy guard, Delete soft-deletes. On success the acting client patches local `messages` state by `message_id` (body/status/edited_at on edit; status/deleted_at on delete); deleted messages render a muted "Message deleted", edited messages show "· edited". Web-only change; no backend production code touched.
- Verification: mix test → 38 passed/35 excluded (backend untouched, still green); mix test --include postgres_integration → 73 passed; web lint → 0 problems; web typecheck → ok; web build → ok.
- Caveats / follow-ups: Edit/delete only update the **acting client's** local state — they are HTTP-only and are NOT propagated to other connected clients, because the realtime channel neither handles a `message:update`/`message:delete` event nor broadcasts `message_updated`/`message_deleted` (verified: `apps/backend/apps/realtime_gateway/lib/realtime_gateway/conversation_channel.ex` only broadcasts `message_created`; `apps/web/src/lib/realtime.ts` only subscribes to `message_created`). Realtime edit/delete propagation is a future backend channel slice. Edit is restricted to text messages (the PATCH path only updates `body`); media-caption editing not in scope. With `MESSAGE_DB_BACKED` off, the backend placeholder edit/delete paths still return sensible shapes so the UI works without a DB.
- Doc corrections: none.

## [2026-06-18] Slice: image preview for media messages
- Status: ✅ green
- Files changed: `apps/web/src/app/chat/page.tsx`
- Behavior: When a media message's `metadata.content_type` starts with `image/` and `metadata.object_key` is present, the chat bubble now renders an inline `<img>` preview (Tailwind `max-h-64 w-full rounded-md object-cover`, lazy-loaded, `onError` hides the image and keeps the link) in addition to the existing "Open media" link. The preview URL is resolved once via the existing `getMediaDownloadUrl` resolver and shared with the link so opening an image does not trigger a second request. Non-image types, missing `object_key`, or a failed image load fall back to the prior behavior unchanged. Web-only change; no backend production code touched.
- Verification: mix test → 38 passed/35 excluded (backend untouched, still green); mix test --include postgres_integration → 73 passed; web lint → 0 problems; web typecheck → ok; web build → ok.
- Caveats / follow-ups: Inline preview requires `metadata.object_key`, which only persists end-to-end with `MESSAGE_DB_BACKED` on (older messages sent before the metadata slice will not preview). With media persistence flags off, `getMediaDownloadUrl` returns a placeholder URL and the `<img>` will fail to load and gracefully fall back to the link. A localized `eslint-disable-next-line @next/next/no-img-element` is used because presigned MinIO URLs are dynamic/remote and `next/image` would require remote-pattern config (deferred as over-engineering for this slice). Video/file inline rendering not in scope.
- Doc corrections: none (backend already returns `metadata.content_type` for media messages — verified in `apps/backend/apps/message_service/lib/message_service/messages.ex:308-319`; this matched the handoff context).

## 2026-06-17

### Done

- Added `apps/web` as the first Next.js + TypeScript + App Router frontend MVP.
- Added Tailwind CSS setup and MVP `/login` and `/chat` pages.
- Added `src/lib/api.ts` for OTP, session, conversation, and message API calls.
- Added `src/lib/realtime.ts` for Phoenix socket setup, conversation channel join, `message:create`, `typing:start`, and `typing:stop`.
- Added `apps/web/.env.example` with API Gateway and realtime socket URLs.
- Added root Makefile helpers for `web-dev`, `web-build`, and `web-lint`.
- Documented frontend setup and the temporary `localStorage` token caveat.
- Attempted to inspect local Docker Compose infrastructure state.
- Docker access was approved, but Docker daemon was not running at `unix:///Users/jaspreetsinghthind/.docker/run/docker.sock`.
- Added Auth Service OTP helper foundation for fixed-width code generation, HMAC code hashing, constant-time verification, and verification-code persistence attrs.
- Added Auth Service token helper foundation for signed access-token envelopes, refresh-token hashing, issue-pair persistence attrs, and refresh-token rotation attrs.
- Added Auth Service rate-limit helper foundation for Redis counter keys, default policy windows, and attempt plans.
- Added offline Auth core unit tests for OTP helpers, token helpers, refresh rotation plans, and rate-limit plans.
- Updated Auth Service README, codemap, roadmap, and AI context for the Auth core foundation.
- Verified Auth core work with `mix format`.
- Verified Auth Service tests with `mix test apps/auth_service/test`.
- Verified backend compile with `mix compile`.
- Verified full backend test suite with `mix test`.
- Re-read PostgreSQL test repo/sandbox integration foundation for Auth, User, and Conversation services.
- Confirmed `config/test.exs` uses `Ecto.Adapters.SQL.Sandbox` for AuthService, UserService, and ConversationService repos.
- Confirmed opt-in PostgreSQL integration tests exist for `users_auth`, `user_profiles`, and `conversations`.
- Created local Docker `chat_platform_test` database and loaded the existing PostgreSQL schema for verification.
- Verified `mix format`, `mix compile`, and plain `mix test`.
- Attempted `mix test --include postgres_integration`; it was blocked because a separate local PostgreSQL process is bound to `127.0.0.1:5432` and shadows Docker's published PostgreSQL port.
- Documented the local PostgreSQL port-conflict troubleshooting path in `LOCAL_DEV_SETUP.md`.
- Fixed User Service and Conversation Service PostgreSQL integration tests to pass dumped UUID binaries to raw PostgreSQL `users_auth` inserts.
- Verified PostgreSQL integration tests now pass with `mix test --include postgres_integration`.
- Added dedicated PostgreSQL test database environment variables in `config/test.exs` so integration tests can target Docker PostgreSQL separately from local development PostgreSQL.
- Updated `.env.example` and local development setup docs with `POSTGRES_TEST_HOST`, `POSTGRES_TEST_PORT`, `POSTGRES_TEST_DATABASE`, `POSTGRES_TEST_USER`, and `POSTGRES_TEST_PASSWORD`.
- Added first DB-backed Auth OTP request slice for `POST /api/v1/auth/otp/request`.
- Added OTP request persistence planning that generates a numeric OTP, stores only the HMAC hash in `verification_codes`, and returns the existing contract response shape.
- Added opt-in API Gateway PostgreSQL integration test proving OTP request creates a `verification_codes` row.
- Kept OTP delivery, OTP verify, JWT signing, Redis live integration, Kafka publishing, frontend code, and API Gateway placeholder behavior outside this slice.
- Added DB-backed Auth OTP verify slice for `POST /api/v1/auth/otp/verify` behind opt-in persistence.
- OTP verify now checks the submitted OTP against the stored OTP hash, rejects expired or consumed codes, finds or creates a `users_auth` row, consumes the verification code, creates or updates a `device_sessions` row, and creates a `refresh_tokens` row storing only the token hash.
- Kept access tokens on the existing signed-envelope helper path without production JWT signing, and did not add SMS/email providers, Redis live integration, Kafka publishing, frontend code, Docker infra changes, or schema changes.
- Documented that explicit verification-code revocation needs a future schema change because `verification_codes` has no `revoked_at` column.
- Added opt-in API Gateway PostgreSQL integration tests for valid OTP verify, existing-user verify, consumed OTP rejection, expired OTP rejection, invalid OTP rejection, and refresh-token hash storage.
- Verified Auth OTP verify slice with `mix format`, `mix compile`, `mix test`, and `mix test --include postgres_integration`.
- Added DB-backed Auth refresh-token rotation slice for `POST /api/v1/auth/refresh` behind opt-in persistence.
- Refresh rotation now hashes the submitted token, rejects missing, expired, revoked, or device-mismatched records, revokes the old token, creates a new `refresh_tokens` row storing only the new token hash, and updates the matching `device_sessions` row.
- Added `auth.refresh_invalid` 401 mapping for invalid refresh attempts while keeping normal placeholder refresh behavior Docker-free.
- Added opt-in API Gateway PostgreSQL integration tests for valid refresh rotation, old-token revocation, new-token hash storage, expired token rejection, revoked token rejection, and invalid token rejection.
- Kept production JWT signing, Redis live integration, Kafka publishing, frontend code, Docker infra changes, and schema changes outside this slice.
- Added DB-backed Auth logout slice for `POST /api/v1/auth/logout` behind opt-in persistence.
- Logout now hashes the submitted refresh token, rejects invalid or already-revoked records with `auth.refresh_invalid`, revokes the active `refresh_tokens` row, and sets the associated `device_sessions.revoked_at`.
- Documented the chosen logout behavior: already-revoked refresh tokens are rejected rather than treated as idempotent success.
- Added opt-in API Gateway PostgreSQL integration tests for valid logout refresh-token revocation, device-session revocation, invalid token rejection, and already-revoked token rejection.
- Kept JWT blacklisting, production JWT signing, Redis live integration, Kafka publishing, frontend code, Docker infra changes, and schema changes outside this slice.
- Added DB-backed Auth session endpoint slice for `GET /api/v1/auth/session` behind opt-in persistence.
- Session lookup now validates the existing signed-envelope access-token helper, reads the `Authorization: Bearer` header in DB-backed mode, verifies `device_sessions` and active `users_auth`, and returns contract-aligned session data.
- Added `auth.session_invalid` 401 mapping for missing/invalid access tokens, revoked sessions, missing users, and token/session mismatches.
- Added opt-in API Gateway PostgreSQL integration tests for valid session lookup, missing Authorization rejection, invalid token rejection, revoked session rejection, and missing-user rejection.
- Kept production JWT signing, JWT blacklisting, Redis live integration, Kafka publishing, frontend code, Docker infra changes, and schema changes outside this slice.

### Current Task

- DB-backed Auth OTP request, OTP verify, refresh-token rotation, logout, and session endpoint slices are in place behind the existing opt-in database-backed test strategy.
- Test database configuration can target Docker PostgreSQL independently with dedicated `POSTGRES_TEST_*` variables.

### Next Step

- Plan User signup/login completion or the next authenticated API slice.

## 2026-06-16

### Done

- Created chat-platform root folder.
- Created documentation folder structure.
- Created initial project files.
- Created README.md.
- Created AI_CONTEXT.md.
- Created ROADMAP.md.
- Added architecture overview.
- Added service catalog.
- Added repo structure document.
- Added codemap.
- Added database design.
- Added Kafka event catalog.
- Added security model.
- Added local development setup document.
- Added .env.example.
- Added Docker Compose setup.
- Added local PostgreSQL, Redis, ScyllaDB, Kafka, Kafka UI, MinIO, and Mailpit.
- Added PostgreSQL init scripts for auth, users, tenants, conversations, media, calls, moderation, and audit tables.
- Added ScyllaDB init CQL for chat_messages keyspace and message timeline tables.
- Added Kafka local topic manifest and topic creation script.
- Mounted PostgreSQL init scripts in Docker Compose.
- Created initial Phoenix/Elixir umbrella-style backend foundation under apps/backend.
- Added backend apps for api_gateway, auth_service, user_service, conversation_service, message_service, and realtime_gateway.
- Added PostgreSQL repo placeholders for auth, user, and conversation services.
- Added Redis, ScyllaDB, and Kafka configuration placeholders.
- Added minimal API Gateway health endpoint at GET /health.
- Added backend README files and updated backend codemap.
- Disabled automatic startup of placeholder service repos so the API Gateway health endpoint can run before database-backed business logic exists.
- Verified Phoenix backend foundation locally.
- Verified mix format completed successfully.
- Verified mix compile completed successfully.
- Verified mix phx.server started successfully.
- Verified API Gateway GET /health returned HTTP 200.
- Added Auth Service API contract documentation.
- Added Auth Service placeholder boundaries for OTP, tokens, sessions, devices, and rate limits.
- Added Auth Service unit test placeholders for boundary modules.
- Verified Auth Service foundation with mix format.
- Verified Auth Service foundation with mix compile.
- Verified Auth Service boundary tests with mix test apps/auth_service/test.
- Exposed Auth API skeleton routes through the Phoenix API Gateway.
- Added API Gateway Auth controller actions for OTP request, OTP verify, refresh, logout, and session.
- Updated Auth Service boundaries to return contract-aligned placeholder responses.
- Added API Gateway controller tests for Auth skeleton success responses and basic validation.
- Verified Auth API skeleton with mix format.
- Verified Auth API skeleton with mix compile.
- Verified Auth Service tests with mix test apps/auth_service/test.
- Verified API Gateway tests with mix test apps/api_gateway/test.
- Fixed Auth API Gateway validation to accept JSON body shapes used by curl clients.
- Updated API Gateway tests to send raw JSON through the Phoenix endpoint.
- Added Phoenix parameter filtering for OTP and token fields in request logs.
- Added User Service API contract documentation.
- Added User Service placeholder boundaries for profiles, settings, and privacy.
- Exposed User API skeleton routes through the Phoenix API Gateway.
- Added API Gateway User controller actions for current profile, profile update, and public profile lookup.
- Added User Service and API Gateway tests for User skeleton placeholder responses.
- Verified User API skeleton with mix format.
- Verified User API skeleton with mix compile.
- Verified User Service tests with mix test apps/user_service/test.
- Verified API Gateway tests with mix test apps/api_gateway/test.
- Added Conversation Service API contract documentation.
- Added Conversation Service placeholder boundaries for conversations, participants, groups, and permissions.
- Exposed Conversation API skeleton routes through the Phoenix API Gateway.
- Added API Gateway Conversation controller actions for create, list, detail, add participant, and remove participant.
- Added Conversation Service and API Gateway tests for Conversation skeleton placeholder responses.
- Verified Conversation API skeleton with mix format.
- Verified Conversation API skeleton with mix compile.
- Verified Conversation Service tests with mix test apps/conversation_service/test.
- Verified API Gateway tests with mix test apps/api_gateway/test.
- Added Message Service API contract documentation.
- Added Message Service placeholder boundaries for messages, receipts, reactions, timeline, and permissions.
- Exposed Message API skeleton routes through the Phoenix API Gateway.
- Added API Gateway Message controller actions for send, list, edit, delete, read receipt, and delivered receipt.
- Added Message Service and API Gateway tests for Message skeleton placeholder responses.
- Verified Message API skeleton with mix format.
- Verified Message API skeleton with mix compile.
- Verified Message Service tests with mix test apps/message_service/test.
- Verified API Gateway tests with mix test apps/api_gateway/test.
- Added Realtime Gateway WebSocket API contract documentation.
- Mounted Realtime Gateway Phoenix socket at API Gateway `/socket`.
- Added Realtime Gateway socket and channel skeletons for conversation, user, and call topics.
- Added placeholder client event handlers for typing, message receipts, and call signaling.
- Added Realtime Gateway channel tests for joins and placeholder client events.
- Verified Realtime Gateway skeleton with mix format.
- Verified Realtime Gateway skeleton with mix compile.
- Verified Realtime Gateway channel tests with mix test apps/realtime_gateway/test.
- Verified API Gateway tests with mix test apps/api_gateway/test.
- Reviewed API skeleton consistency across Auth, User, Conversation, Message, and Realtime contracts.
- Added shared API Gateway invalid-request error response helper.
- Added missing invalid-request tests for Auth refresh/logout, User update, Conversation participant add, and Message edit skeleton endpoints.
- Aligned API contract examples with current placeholder skeleton responses.
- Verified API skeleton consistency cleanup with mix format.
- Verified API skeleton consistency cleanup with mix compile.
- Verified full backend test suite with mix test.
- Added Auth Service Ecto schemas for users_auth, verification_codes, device_sessions, refresh_tokens, and login_attempts.
- Added Auth Service data-access boundaries for auth users, verification codes, device sessions, refresh tokens, and login attempts.
- Added safe Auth Service persistence tests for schema changesets and boundary changeset builders.
- Verified Auth Service persistence foundation with mix format.
- Verified Auth Service persistence foundation with mix compile.
- Verified full backend test suite with mix test.
- Added User Service Ecto schemas for user_profiles, user_settings, and user_privacy_settings.
- Added User Service data-access boundaries for profiles, settings, and privacy settings.
- Added safe User Service persistence tests for schema changesets and boundary changeset builders.
- Verified User Service persistence foundation with mix format.
- Verified User Service persistence foundation with mix compile.
- Verified full backend test suite with mix test.
- Added Conversation Service Ecto schemas for conversations, conversation_participants, conversation_settings, and group_profiles.
- Added Conversation Service data-access boundaries for conversations, participants, conversation settings, and group profiles.
- Added safe Conversation Service persistence tests for schema changesets and boundary changeset builders.
- Verified Conversation Service persistence foundation with mix format.
- Verified Conversation Service persistence foundation with mix compile.
- Verified full backend test suite with mix test.
- Added Message Service ScyllaDB query-plan foundation for timeline writes, timeline reads, receipts, reactions, and user inbox projection.
- Added safe Message Service persistence tests for parameterized CQL query plans.
- Verified Message Service ScyllaDB persistence foundation with mix format.
- Verified Message Service ScyllaDB persistence foundation with mix compile.
- Verified full backend test suite with mix test.
- Added shared infrastructure client behaviour foundation for Redis, Kafka producer, Kafka consumer, and ScyllaDB boundaries.
- Added safe shared config helpers for existing Redis, Kafka, and ScyllaDB placeholders.
- Added dummy infrastructure adapters and offline tests that do not require live Redis, Kafka, or ScyllaDB.
- Verified shared infrastructure client foundation with mix format.
- Verified shared infrastructure client foundation with mix compile.
- Verified full backend test suite with mix test.
- Added PostgreSQL Sandbox test support helpers for Auth, User, and Conversation services.
- Added opt-in PostgreSQL integration tests for `users_auth`, `user_profiles`, and `conversations` schema insert/select paths.
- Documented local `chat_platform_test` setup and `mix test --include postgres_integration` usage.
- Added DB-aware Realtime Gateway socket/channel foundations behind opt-in flags.
- Added Conversation Channel authorization through Conversation Service when conversation persistence is enabled.
- Added `message:create` and `message:new` channel event boundary through Message Service with in-memory adapter coverage.
- Added Media Service upload/download boundary with safe in-memory storage adapter coverage.
- Added API Gateway media upload, complete, and download URL routes.
- Added Message Service media-message validation for `message_type: "media"` with required `media_id` and optional `caption`.
- Added API Gateway and Realtime Gateway media-message coverage through the existing message creation boundary.
- Added SharedInfra API rate limiter boundary with in-memory test adapter and Redis query-plan placeholder.
- Added API Gateway OTP request route rate-limit plug for `POST /api/v1/auth/otp/request` behind opt-in config.
- Added Auth token config boundary for access TTL, refresh TTL, issuer, and audience while keeping signed-envelope tokens.
- Hardened DB-backed refresh/session behavior so refresh tokens must match the active device session hash and logout/revoked sessions invalidate access-token session lookup.
- Added backend CI workflow for Docker-free format, compile, and test checks on push to main and pull requests.
- Added root Makefile helpers for backend tests, integration tests, formatting, compile, and local infra up/down.
- Documented local backend test commands, PostgreSQL integration test setup, and deferred live Redis/MinIO/Scylla CI integration.
- Added Redis-backed SharedInfra rate limiter adapter using direct Redis TCP commands with `INCR`, first-create `EXPIRE`, and `TTL` retry-after handling.
- Kept default tests Docker-free with the in-memory rate limiter adapter and added opt-in `:redis_integration` coverage for live local Redis.
- Documented Redis-backed API rate limiting config with `RATE_LIMITER_REDIS_URL`, `RATE_LIMITER_FAIL_OPEN`, and `API_RATE_LIMITING_ENABLED`.
- Added MinIO/S3 presigned URL adapter for Media Service using local AWS Signature V4 signing without adding an external dependency.
- MinIO adapter now returns presigned PUT upload URLs, presigned GET download URLs, and a no-network complete-upload success boundary while leaving object upload verification for later.
- Documented MinIO media config with `MEDIA_STORAGE_ADAPTER`, `MINIO_ENDPOINT`, `MINIO_BUCKET`, `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY`, `MINIO_REGION`, `MINIO_URL_EXPIRES_SECONDS`, and `MINIO_PATH_STYLE`.
- Completed the Scylla client boundary with a config-backed `SharedInfra.Scylla.Client`, safe unavailable default, richer contact point/keyspace/timeout config, and Message Service ScyllaAdapter wiring through the shared client.
- Kept live Cassandra/Scylla driver execution deferred because no client dependency exists in the umbrella and adding one is a larger integration risk.
- Documented Scylla message storage config with `MESSAGE_STORE_ADAPTER`, `SCYLLA_CONTACT_POINTS`, `SCYLLA_KEYSPACE`, and `SCYLLA_TIMEOUT_MS`.

### Current Task

- Scylla/Cassandra client boundary slice is complete behind config while normal backend tests remain Docker-free.

### Next Step

- Start local Docker infrastructure with a fresh PostgreSQL volume.
- Apply ScyllaDB CQL init script.
- Create Kafka topics from local topic manifest.
- Plan PostgreSQL integration CI service setup, production JWT signing/key rotation, live Cassandra/Scylla driver adapter evaluation, media metadata persistence, upload completion verification, and media ownership/access checks.
