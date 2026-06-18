# Decision Log

Architecture decisions, newest first. Each entry: context → decision → rationale → status.

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
