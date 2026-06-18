# Decision Log

Architecture decisions, newest first. Each entry: context → decision → rationale → status.

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
