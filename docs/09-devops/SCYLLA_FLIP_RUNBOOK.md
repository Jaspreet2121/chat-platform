# Scylla ladder runbook — rung 4 (dual_write) and rung 7 (the read flip)

> ## STATE CHECK [UPDATED 2026-08-09] — THE FLIP HAPPENED ON 2026-08-08. THIS IS NOW HISTORY.
>
> Production runs **`MESSAGE_STORE_ADAPTER=scylla`** (writes AND reads), sourced from the host
> `.env` — the compose file requires it via `${VAR:?}` and the conversation container reads the
> same variable for its reconciler interlock. The ladder below was CLIMBED: the cutover went
> direct to the plain `scylla` adapter on 2026-08-08 (~11:01 UTC), skipping the staged
> `dual_write`/`scylla_read` rungs this runbook was written for. What this document describes is
> therefore a PLAN that history took a shortcut past — keep it for the procedure patterns and the
> abort criteria, but do not read the rung state as current.
>
> **If you are here to ROLL BACK:** the old sed command in the handoff doc still silently no-ops,
> and rollback is NO LONGER LOSSLESS: rows written to Scylla since the cutover were never written
> to Postgres, so `MESSAGE_STORE_ADAPTER=postgres` makes every post-cutover message invisible.
> Edit `.env` (not the compose file — see the 2026-08-08 compose commits for why hand-edits
> diverge), and expect the frozen-table consequences recorded in DECISION_LOG 2026-08-08: the
> inbox projection self-gates back off, InboxCounters' recount interlock re-opens, and search
> reverts to the live-Postgres path only if the table is still populated.
>
> Post-cutover state that lives elsewhere, deliberately not restated: the inbox/search consumers
> ([docker-compose.prod.yml] message block), the reconciler interlock and repair
> (DECISION_LOG 2026-08-08, `MessageService.InboxRepair`), the search copy decision
> (DECISION_LOG 2026-08-08).

Written to be executed by someone who didn't write it, at 2am, under pressure. Every step has the
exact command, the expected output, and the ABORT criterion. If any observation matches an abort
criterion: **go to ROLLBACK immediately. Do not debug while flipped.**

**This document covers TWO rungs, each with its own steps, stop conditions and rollback.** Read the
one you are on:

* **[RUNG 4 — enable `dual_write`](#rung-4--enable-dual_write)** — writes mirror to Scylla, reads
  unaffected. This is the next rung.
* **[RUNG 7 — the read flip](#rung-7--the-read-flip)** — reads served from Scylla. Several rungs away,
  and additionally blocked (see the STATE CHECK).

**What "the flip" (rung 7) is:** reads served from Scylla, writes still dual (Postgres never stops
receiving them — that is what makes rollback instant and lossless). It is an OPERATIONAL decision
taken deliberately — never something a deploy or merge does. All adapters deploy inert.

**Step numbers restart in each rung's section.** "Step 4" in rung 4 is not "step 4" in rung 7.

---

# RUNG 4 — enable `dual_write`

**Ladder position is in the STATE CHECK at the top of this file; it is not repeated here.**

Postgres stays the transaction of record. The Scylla write becomes a detached async mirror. **Reads
are unaffected — nothing reads Scylla at this rung.** No user-visible change is expected, which is a
prediction, not a fact; the stop conditions below are how you find out.

### What actually changes [VERIFIED 2026-08-05]

**Env-only, single service.** Only `message` reads `MESSAGE_STORE_ADAPTER`
([docker-compose.prod.yml:153](../../docker-compose.prod.yml#L153)) — it is the sole occurrence in
the file. The gateway runs `MESSAGE_CLIENT_ADAPTER: http` against `MESSAGE_SERVICE_URL:
http://message:4104`, so the gateway and every other service resolve nothing and are unaffected.

**Why a recreate is needed at all — and why the console rollback is not.** These are the same
mechanism, read in two places:

| Layer | When it is read | Evidence |
|---|---|---|
| `System.get_env("MESSAGE_STORE_ADAPTER")` → Application env | **boot only** | [runtime.exs:156](../../apps/backend/config/runtime.exs#L156) |
| `Application.get_env(...)` → the adapter module | **every call** | [message_store.ex:126-132](../../apps/backend/apps/message_service/lib/message_service/message_store.ex#L126-L132) |

So the compose edit needs a container recreate (runtime.exs only runs at boot), while a remote-console
`Application.put_env/3` takes effect on the **next call, with no restart**. That is what makes the
instant rollback possible.

**No rebuild.** The image is unchanged. Use `--no-build` — compose's bake definition builds six
services together, so an unqualified `up` can rebuild far more than you intended. Use `--no-deps` —
`service-base` carries `depends_on: postgres`, and Postgres must not be recreated for an env change.

### Step 0 — BASELINE. Do this BEFORE the edit.

**Without this, the after-state is unreadable.** A failure count of zero means *either* "mirroring
works" *or* "nothing ran" — those are the same reading. Only a **delta** separates them, and a delta
needs a before.

```
docker compose -f docker-compose.prod.yml exec -T postgres \
  psql -U chat_user -d chat_platform -tAc "SELECT count(*) FROM messages;"

docker compose -f docker-compose.prod.yml exec -T scylla \
  cqlsh -e "SELECT COUNT(*) FROM chat_messages.messages_by_conversation;"
```

Write both numbers down. **`COUNT(*)` in CQL is a full table scan** — acceptable at current row
counts for a one-off baseline, and it must not become a habit or a monitoring query.

### Step 1 — the edit, BY HAND

Open `docker-compose.prod.yml`, line 153:

```
MESSAGE_STORE_ADAPTER: postgres      ->      MESSAGE_STORE_ADAPTER: dual_write
```

**Do not use `sed` here.** This document records why (see ROLLBACK): a pattern that does not match
changes nothing and still exits 0, so the command reports success having done nothing.

### Step 2 — recreate `message` only

```
docker compose -f docker-compose.prod.yml up -d --no-deps --no-build message
```

### Step 3 — VERIFY. NOT OPTIONAL.

**Step 2 exiting 0 proves nothing about which adapter is loaded.** It proves compose ran.

```
docker inspect chat-platform-prod-message-1 \
  --format '{{range .Config.Env}}{{println .}}{{end}}' | grep MESSAGE_STORE_ADAPTER
```
EXPECT: `MESSAGE_STORE_ADAPTER=dual_write`

**Caveat that matters after any console change:** `docker inspect` (and `exec env`) show what the
container will BOOT with — not what is currently serving. If anyone has run `Application.put_env/3`,
the live adapter can differ from both. The only authority then is the console:

```
docker compose -f docker-compose.prod.yml exec message bin/message_service remote
```
```elixir
Application.get_env(:message_service, :message_store_adapter)
```

### Step 4 — send 2–3 test messages, then read the four states

Re-run both Step 0 counts, plus:

```
docker compose -f docker-compose.prod.yml exec -T postgres psql -U chat_user -d chat_platform -c \
"SELECT op, left(reason,80) AS reason, count(*)
   FROM scylla_mirror_failures
  WHERE resolved_at IS NULL
  GROUP BY 1,2 ORDER BY 3 DESC;"
```

| Δ postgres | Δ scylla | unresolved failures | Verdict |
|---|---|---|---|
| > 0 | **= Δ postgres** | 0 | ✅ **mirroring works** |
| > 0 | 0 | **> 0** | ⚠️ **failing loudly** — read `reason`. This is the GOOD failure: it is recorded and repairable. |
| > 0 | 0 | **0** | 🔴 **nothing ran** — the adapter never took effect. Go back to Step 3. |
| > 0 | partial | 0 | 🔴 **failing silently** — the worst state. |

**The last two rows are the pair a dashboard cannot separate** — both look like a quiet, healthy
system. Separate them with Step 3's `docker inspect` (did the adapter load?) and:

```
docker compose -f docker-compose.prod.yml logs --since 10m message | grep -i "shadow mirror"
```

A `failed to RECORD a failure` line is the **only** signal of the silent case: it means the mirror
failed *and* could not write its failure row, so the failure table will under-report.

### STOP CONDITIONS — roll back, do not investigate

Any one of these, at any point in the first ten minutes:

* **Message-send latency increases at all.** The mirror is detached and must add **zero** request
  latency. Any increase means the isolation is not holding, and the isolation is the entire premise.
* **Unresolved failures grow continuously** rather than settling to a fixed number.
* **`failed to RECORD a failure` appears in the logs** — you are now blind, which is worse than
  failing.
* **message-service memory climbs toward its `384m` limit** — that is the unbounded task pool
  (below) materialising.
* **Any user-visible send error.** Postgres is authoritative here; `dual_write` must not be able to
  affect a send at all.

### ROLLBACK from rung 4

**Instant — takes effect on the next call, no restart:**
```
docker compose -f docker-compose.prod.yml exec message bin/message_service remote
```
```elixir
Application.put_env(:message_service, :message_store_adapter,
                    MessageService.MessageStore.PostgresAdapter)
```

> ### ⚠ THE `put_env` TRAP — READ BEFORE GOING BACK TO BED
>
> The console rollback changes the RUNNING adapter and **leaves line 153 saying `dual_write`.** The
> next container restart — a deploy, an OOM kill, a host reboot — **silently re-enables dual_write**,
> with nobody watching. Rolling back at 2am and stopping here ARMS A DELAYED RE-ENABLE.
>
> The file revert below is not optional cleanup. It is the second half of the rollback.

**Durable — revert line 153 to `postgres`, then:**
```
docker compose -f docker-compose.prod.yml up -d --no-deps --no-build message
```

**VERIFY — NOT OPTIONAL, on either path:**
```
docker inspect chat-platform-prod-message-1 \
  --format '{{range .Config.Env}}{{println .}}{{end}}' | grep MESSAGE_STORE_ADAPTER
```
EXPECT: `MESSAGE_STORE_ADAPTER=postgres`

### KNOWN STRUCTURAL GAP — recorded, not fixed [VERIFIED 2026-08-05]

**Nothing bounds the number of in-flight mirror tasks.**
[application.ex:32](../../apps/backend/apps/message_service/lib/message_service/application.ex#L32) is
`{Task.Supervisor, name: MessageService.ShadowMirror.TaskSupervisor}` with **no `max_children`**,
which defaults to `:infinity`.

What IS bounded:
* per-task lifetime — the 2000ms timeout applies to **both** `prepare` and `execute`
  ([xandra_adapter.ex:134-135](../../apps/backend/apps/shared_infra/lib/shared_infra/scylla/xandra_adapter.ex#L134-L135)),
  so worst case is **~4s per task**, not 2s;
* driver concurrency — `pool_size: 1`, so every mirror serialises on one connection;
* retries — none in-task by design; the failure ROW is the retry mechanism.

In-flight tasks therefore accumulate at roughly *write-rate × ~4s* under a hung-but-reachable Scylla.

**Calibration, and it is counter-intuitive:** Scylla **fully down is the CHEAP case** — the client
short-circuits on a local `Process.whereis` check and never makes a network call. **Scylla up-but-slow
is the expensive one.** Do not assume a dead Scylla is the bad scenario.

**Write amplification — how a Scylla problem becomes a Postgres problem:** every failed mirror writes
a row to `scylla_mirror_failures`. Under a sustained Scylla-slow event, Postgres write load roughly
**doubles** (the message insert plus the failure insert).

**This is not a live risk at current volume** — at the traffic this system carries, in-flight tasks
stay near zero. It is recorded because it is a real structural gap, it is what the memory and
latency stop conditions above exist to catch, and it must be fixed before any rung that puts the
mirror on the read path.

---

# RUNG 7 — the read flip

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
   **[SCOPE, VERIFIED 2026-08-05] Those numbers are from a LOCAL drill, not production.**
   `scripts/rollback-drill.sh` runs `MIX_ENV=test`, in-BEAM, against the **dev** containers in
   `infra/docker/docker-compose.yml`. It is real evidence that the adapter switch is fast and
   lossless *in a test harness*. **No production rollback drill has ever been executed**, and
   precondition 5 below records why an in-BEAM drill cannot see HTTP-boundary failures — the same
   reason these timings cannot stand in for a production one.
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
EXPECT: **`MESSAGE_STORE_ADAPTER=shadow_read`**.
ABORT if it shows anything else — the system is not in the state this runbook assumes.

**[CORRECTED 2026-08-05]** This previously read *"EXPECT `postgres` (or `dual_write` if the C7 window is still running)"*, which contradicted precondition 2: that precondition requires `shadow_read` to have run for ≥48h, so by the time you reach this step the adapter cannot still be `postgres`. Reaching the flip from `postgres` means rungs 4–6 were skipped.

Note `exec env` shows the BOOT value. If a console `put_env` has been used, confirm the live adapter with `Application.get_env(:message_service, :message_store_adapter)` from a remote console.

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

## ROLLBACK from rung 7 — the whole point

> ### DO NOT USE THE `sed` COMMAND FROM THE HANDOFF DOC [VERIFIED 2026-08-05]
>
> ```
> sed -i '153s/scylla_read/dual_write/' docker-compose.prod.yml     # ← DOES NOTHING
> ```
>
> Line 153 currently reads `postgres`. **`sed` matches nothing, changes nothing, and exits 0.** An
> operator running it mid-incident sees a successful command and believes the rollback happened.
>
> **`sed`'s exit code is not proof.** It succeeds when its pattern is absent — which is exactly the
> case here. Running the command is what was mistaken for it working. Whatever you do below, the
> rollback is not done until the VERIFY step confirms the value, not until a command exits 0.

**1. In-BEAM (instant, takes effect on the next request):**
```
docker compose -f docker-compose.prod.yml exec message bin/message_service remote
```
```elixir
Application.put_env(:message_service, :message_store_adapter, MessageService.MessageStore.DualWriteAdapter)
```

**2. Make it durable — EDIT the value, do not sed-on-a-guess.** Open
`docker-compose.prod.yml`, find `MESSAGE_STORE_ADAPTER:` (~line 153) and set it to the rung you are
returning to (`shadow_read`, `dual_write`, or `postgres`), then:
```
docker compose -f docker-compose.prod.yml up -d message
```

**3. VERIFY — this step is the point, and it is not optional:**
```
docker inspect chat-platform-prod-message-1 \
  --format '{{range .Config.Env}}{{println .}}{{end}}' | grep MESSAGE_STORE_ADAPTER
```
EXPECT the value you just set. If it shows anything else, the rollback did **not** happen regardless
of what any previous command returned.

[VERIFIED] `MESSAGE_STORE_ADAPTER` is hardcoded in `docker-compose.prod.yml`, **not** in `.env` —
editing `.env` and restarting will not change it, which is what an operator would try first.

EXPECT: next request serves from Postgres. **Nothing is lost** — writes never left Postgres; the
drill proved 17/17 messages present and field-identical after a flip + mid-traffic Scylla kill +
rollback. Measured: the switch itself is milliseconds (17 ms including the first verified
Postgres-served read); the operator's end-to-end time is dominated by typing — budget one minute.

If the container restarts before step 4's edit is reverted, it comes back FLIPPED — that is why
step 4 must be reverted as part of rollback, immediately after the put_env.

> **This is the same `put_env` trap documented at the rung-4 rollback.** A console rollback changes
> the RUNNING adapter and leaves the file saying otherwise; the next restart — deploy, OOM kill, host
> reboot — silently re-applies it, with nobody watching. Rolling back and stopping there ARMS A
> DELAYED RE-ENABLE. The file revert is the second half of the rollback, not cleanup.

## What a user experiences during a Scylla outage while flipped (measured in the drill)

* **Sends: succeed normally** — Postgres is authoritative; the failed mirrors are recorded rows the
  repair path re-drives.
* **Timeline/message reads: fail loudly with 503** (`:message_store_unavailable`). Not silent, not
  stale, not 400 — the drill originally caught raw `Xandra.ConnectionError` structs falling through
  gateway clauses to a 400 "invalid request"; the adapter now normalises every driver-level error to
  the 503 path. A loudly-broken read is the designed behaviour; silently-stale would be the finding.
