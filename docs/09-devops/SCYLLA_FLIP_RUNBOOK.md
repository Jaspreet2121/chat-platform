# Scylla read-flip runbook

Written to be executed by someone who didn't write it, at 2am, under pressure. Every step has the
exact command, the expected output, and the ABORT criterion. If any observation matches an abort
criterion: **go to ROLLBACK immediately. Do not debug while flipped.**

**What "the flip" is:** reads served from Scylla, writes still dual (Postgres never stops receiving
them — that is what makes rollback instant and lossless). It is an OPERATIONAL decision taken here,
deliberately — never something a deploy or merge does. All adapters deploy inert; production runs
`MESSAGE_STORE_ADAPTER=postgres` until step 4 of this document.

## Preconditions — all five, no exceptions

1. **The C7 verification gate has passed:** `MessageService.ScyllaBackfill.report()` showed
   `stale_diff_total: 0` AND `unresolved_failures: 0` on TWO consecutive reports ≥ 10 minutes apart,
   during steady traffic.
2. **The shadow-read window is clean:** `MESSAGE_STORE_ADAPTER=shadow_read` has run for ≥ 48h and
   `SELECT count(*) FROM scylla_mirror_failures WHERE op='read_diff' AND inserted_at > now() - interval '48 hours'`
   returns **0**.
3. **Scylla is up with headroom.** Idle it was measured at 79 MiB; under real load budget
   **300–600 MiB steady, 1 GiB Seastar cap, 1500 MiB container backstop** — the box must show
   ≥ 1.5 GiB available in `free -h` before flipping, or do not flip.
4. **The rollback drill is green on this codebase:** `./scripts/rollback-drill.sh` ends with
   `ZERO LOSS: PROVEN`. Last executed 2026-08-01: flip 0 ms, outage behaviour verified
   (writes succeed / reads 503 loudly), rollback 17 ms in-BEAM, 17/17 messages zero loss.
5. **The scylla gate is green, INCLUDING the HTTP-boundary suite**
   (`./scripts/test-scylla.sh` — ScyllaHttpBoundaryTest must be among the listed suites and passing).
   Provenance: the C8 drill flips adapters in-BEAM and therefore cannot meet a string `limit`, which
   is exactly how a crash-on-every-chat-open passed every precondition above and reached production
   on the first flip attempt (2026-08-01, rolled back). A precondition that can't see the failure
   class it exists to prevent needs the failure class named next to it — that class is
   HTTP-boundary typing, and only the wire-path suite sees it.

**Known product change at flip:** cross-conversation message search on web STOPS WORKING — 503
`search.unavailable`, by recorded decision (DECISION_LOG 2026-08-01). If external users exist, that
decision has EXPIRED: stop, ship the search index first.

## The flip

### 1. Confirm the current state

```
docker compose -f docker-compose.prod.yml exec -T message env | grep MESSAGE_STORE_ADAPTER
```
EXPECT: `MESSAGE_STORE_ADAPTER=postgres` (or `dual_write` if the C7 window is still running).
ABORT if it shows anything else — the system is not in the state this runbook assumes.

### 2. Confirm Scylla health and the shadow lag

```
docker compose -f docker-compose.prod.yml exec -T scylla nodetool status
docker compose -f docker-compose.prod.yml exec -T postgres psql -U chat_user -d chat_platform -tAc \
  "SELECT count(*) FROM scylla_mirror_failures WHERE resolved_at IS NULL"
```
EXPECT: `UN` (Up/Normal) in nodetool; `0` unresolved failures.
ABORT if nodetool shows anything but UN, or unresolved > 0 (run
`MessageService.ScyllaBackfill.repair_failures()` and re-check; if it won't reach 0, do not flip).

### 3. Flip — remote console, instant and reversible

```
docker compose -f docker-compose.prod.yml exec message bin/message_service remote
```
```elixir
Application.put_env(:message_service, :message_store_adapter, MessageService.MessageStore.ScyllaReadAdapter)
```
EXPECT: `:ok`. Takes effect on the next request — the drill measured the switch at 0 ms.

### 4. Make it durable (so a container restart doesn't silently roll back)

Edit the message service env in `docker-compose.prod.yml`: `MESSAGE_STORE_ADAPTER=scylla_read`.
Do NOT restart now — the put_env already did the flip; the file edit is for the next restart.

### 5. Watch for 15 minutes

```
# a) sends still work end-to-end (any test conversation)
# b) timelines load (this is now Scylla serving)
docker compose -f docker-compose.prod.yml logs -f message | grep -iE "store unavailable|MEDIA PROJECTION|read_diff|error"
```
EXPECT: routine traffic, no growing error lines.
ABORT — go to ROLLBACK — if ANY of these appear:
  * repeated `-> store unavailable` lines (Scylla is failing under real read load);
  * users report timelines empty/stale while sends succeed (silent wrongness — worse than errors);
  * `MEDIA PROJECTION WRITE FAILED` recurring (fan-out failing under load);
  * message-service latency alarms.

## ROLLBACK — the whole point

```
docker compose -f docker-compose.prod.yml exec message bin/message_service remote
```
```elixir
Application.put_env(:message_service, :message_store_adapter, MessageService.MessageStore.DualWriteAdapter)
```
Then revert the compose file edit from step 4.

EXPECT: next request serves from Postgres. **Nothing is lost** — writes never left Postgres; the
drill proved 17/17 messages present and field-identical after a flip + mid-traffic Scylla kill +
rollback. Measured: the switch itself is milliseconds (17 ms including the first verified
Postgres-served read); the operator's end-to-end time is dominated by typing — budget one minute.

If the container restarts before step 4's edit is reverted, it comes back FLIPPED — that is why
step 4 must be reverted as part of rollback, immediately after the put_env.

## What a user experiences during a Scylla outage while flipped (measured in the drill)

* **Sends: succeed normally** — Postgres is authoritative; the failed mirrors are recorded rows the
  repair path re-drives.
* **Timeline/message reads: fail loudly with 503** (`:message_store_unavailable`). Not silent, not
  stale, not 400 — the drill originally caught raw `Xandra.ConnectionError` structs falling through
  gateway clauses to a 400 "invalid request"; the adapter now normalises every driver-level error to
  the 503 path. A loudly-broken read is the designed behaviour; silently-stale would be the finding.
