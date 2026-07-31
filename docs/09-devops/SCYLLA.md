# ScyllaDB — Phases A (container + schema) and B (driver)

**Status: the driver is live; the STORE is still Postgres. Scylla serves no application reads or
writes.** Phase A brought the container up and loaded the schema; Phase B connected a real CQL driver
to it. `MESSAGE_STORE_ADAPTER` remains `postgres`, and nothing writes message rows to Scylla.

What these phases deliberately do **not** do:

- do **not** change `MESSAGE_STORE_ADAPTER` (still `postgres` everywhere);
- do **not** add `depends_on: scylla` to any service — nothing can fail because Scylla is absent;
- do **not** touch existing message data, or the CQL schema's key/table design;
- do **not** write anything into `messages_by_conversation` — the write plans' value types do not yet
  match the CQL column types (see Phase D below), which is precisely why no write happens yet.

With the `scylla` profile **off** (the default) a plain `docker compose -f docker-compose.prod.yml up -d`
is byte-identical to before this change.

---

## 1. Bring the container up

```bash
cd /path/to/chat-platform
docker compose -f docker-compose.prod.yml --profile scylla up -d scylla
```

Wait for `healthy` (first boot initialises the system keyspaces and is slow — the healthcheck allows a
90s `start_period`, expect ~1–2 minutes):

```bash
docker compose -f docker-compose.prod.yml ps scylla
# STATUS should read: Up (healthy)
```

If it is still `starting`, watch it:

```bash
docker compose -f docker-compose.prod.yml logs -f scylla
```

## 2. Load the schema (one-shot, idempotent)

The Scylla image has **no** `/docker-entrypoint-initdb.d` equivalent — unlike Postgres it will not run
`*.cql` from a mounted folder. The schema is therefore loaded by an explicit one-shot `cqlsh` exec.
This is deliberate: an auto-init sidecar would be fragile (ordering, retries, partial application) for
something run once per volume.

```bash
docker compose -f docker-compose.prod.yml exec -T scylla \
  cqlsh -f - < infra/docker/scylladb/init/001_chat_messages.cql
```

`001_chat_messages.cql` is **idempotent** — every statement is `CREATE ... IF NOT EXISTS` (1 keyspace +
4 tables), so re-running it is safe and is the correct response to any doubt about whether it applied.

## 3. Verify

```bash
# The keyspace and its four tables.
docker compose -f docker-compose.prod.yml exec -T scylla cqlsh -e "DESCRIBE KEYSPACE chat_messages"

# Expect these four:
#   messages_by_conversation, message_receipts_by_conversation,
#   message_reactions_by_message, messages_by_user_inbox
docker compose -f docker-compose.prod.yml exec -T scylla \
  cqlsh -e "SELECT table_name FROM system_schema.tables WHERE keyspace_name = 'chat_messages';"

# Node is serving CQL and owns its token ranges.
docker compose -f docker-compose.prod.yml exec -T scylla nodetool status
```

## 4. Check the memory impact (do this — the box is tight)

The box is **7.6 GB total with ~4.4 GB available and 14 containers already running**. Capture before
and after so a regression is attributable:

```bash
# BEFORE bringing scylla up
free -h
docker stats --no-stream

# AFTER it reports healthy
free -h
docker stats --no-stream | grep -E "NAME|scylla"
```

Expect Scylla to settle around **1–1.4 GB RSS** (the 1G Seastar budget plus non-Seastar overhead), well
under its 1500m container cap. If the container is OOM-killed (`docker inspect` shows
`OOMKilled: true`), raise `mem_limit` **before** raising `--memory` — the Seastar budget is the thing
protecting the rest of the platform.

To back it out completely:

```bash
docker compose -f docker-compose.prod.yml --profile scylla down scylla   # keeps the volume
docker volume rm chat-platform-prod_scylla_data                          # discards the schema too
```

---

## 5. Why those memory flags

Scylla is designed to own its machine: **by default it claims all available RAM**, which on this host
would OOM-kill Postgres, Kafka, LiveKit and the seven app services. Every flag is load-bearing:

| Flag | Why |
|---|---|
| `--smp 1` | One shard. The default is one shard per core, and each reserves its own memory slice and threads — on a shared box that multiplies the footprint for no throughput we can use. |
| `--memory 1G` | Hard cap on Scylla's own (Seastar) allocation. Without it the default is "everything free" — precisely the OOM. |
| `--overprovisioned 1` | Tells Seastar it does **not** own the machine: no CPU pinning, no busy-poll spinning, no real-time scheduling assumptions. Correct for a container sharing one core. |
| `--reserve-memory 0` | Stops Scylla *also* holding back headroom "for the OS" on top of `--memory`; with both set it would otherwise reserve twice and overshoot the 1 GB budget. |
| `--developer-mode 1` | **Required** on a shared Docker host: skips the production disk/AIO checks (XFS, direct-IO queue depth) that otherwise make Scylla refuse to boot on an overlay filesystem. |

`mem_limit: 1500m` is a **backstop** above the 1 GB Seastar budget, covering non-Seastar RSS — the same
belt-and-braces as the Kafka container's cap.

**Image tag:** pinned to `scylladb/scylla:6.2` (never `latest`). Note the deliberate skew: the dev infra
compose (`infra/docker/docker-compose.yml`) runs `scylladb/scylla:5.4` with `--memory 750M` and no
healthcheck. Prod is pinned separately because its constraints differ (shared box, no host-published
ports, health-gated). Verify the tag pulls on the target host before a real deploy; the dev/prod tag
skew is still open and worth closing next time either is touched.

---

## 6. Config wiring

`config/runtime.exs` reads two env vars, **gated so that absence writes no config at all**:

| Env | Default when the block runs | Effect |
|---|---|---|
| `SCYLLA_NODES` | *(gates the block — unset means nothing is configured)* | `"scylla:9042"`, or a comma list `"a:9042,b:9043"`. A bare host defaults to port 9042. Parsed into the `{host, port}` tuples `SharedInfra.Config.Scylla` expects. |
| `SCYLLA_KEYSPACE` | `chat_messages` | Keyspace name. |

Since **Phase B**, the **message service** — and only it, being the sole consumer — sets both in
compose (`SCYLLA_NODES=scylla:9042`, `SCYLLA_KEYSPACE=chat_messages`). Setting `SCYLLA_NODES` does two
things and only two: it configures the node list, and it points the client boundary at the real Xandra
adapter so a supervised cluster starts. It does **not** select the store — `MESSAGE_STORE_ADAPTER`
does that, and it is still `postgres`.

---

## 7. Phase B — the driver (shipped)

`SharedInfra.Scylla.XandraAdapter` is a supervised `Xandra.Cluster` behind the existing
`SharedInfra.Scylla.Client` boundary. **Driver only — the store adapter is still Postgres.**

It starts **only** when `SCYLLA_NODES` is configured, which compose now sets on the **message service
alone** (`SCYLLA_NODES=scylla:9042`, `SCYLLA_KEYSPACE=chat_messages`). Absent env → no child, and the
boundary keeps returning the `:scylla_unavailable` stub exactly as before.

### Boot safety (the design constraint)

message_service serves all production chat from Postgres, so Scylla must never be able to take it
down. Three guarantees, all tested:

- `XandraAdapter.start_link/1` **never returns an error** — on any failure it logs and returns
  `:ignore`, so the supervisor carries on without the child and the app boots;
- `sync_connect` is **off**, so boot never blocks on a TCP connect (Xandra connects in the background
  and reconnects on its own);
- every call checks the cluster is alive first — with it absent or dead, callers get
  `{:error, :scylla_unavailable}` and `MessageStore.ScyllaAdapter` maps that to
  `:message_store_unavailable`, exactly as before.

Proven directly: with `SCYLLA_NODES` pointed at a dead host, `message_service` starts, its supervisor
stays alive, the client returns an error instead of raising, and message create/list still work.

### Verify the driver is live

```bash
# The cluster only logs this line when SCYLLA_NODES is set:
docker compose -f docker-compose.prod.yml logs message | grep -i scylla
# expect: scylla: Xandra cluster started (["scylla:9042"]) — driver only, store is postgres

# The store is UNCHANGED — this must still say postgres:
docker compose -f docker-compose.prod.yml exec -T message env | grep MESSAGE_STORE_ADAPTER
```

A live round-trip test exists but is excluded by default:

```bash
docker compose -f docker-compose.prod.yml --profile scylla up -d scylla
cd apps/backend
SCYLLA_TEST_NODES=localhost:9042 mix test --include scylla_integration
```

It runs `SELECT release_version FROM system.local` — deliberately a **read**. A write smoke would hit
the Phase D type problem below and put junk in a table whose migration is undesigned.

### Deploy note

Phase B adds env to the message service, so **deploying it recreates the message container** — the
first behaviour-affecting change of this Scylla work. Everything else stays as it was.

## 8. The position (2026-08-01): hybrid end-state, measured trigger

Recorded in `docs/11-decisions/DECISION_LOG.md` so it is not rediscovered as a mystery later:

- Phases A + B shipped; `MESSAGE_STORE_ADAPTER` is `postgres` and the `scylla` profile is off —
  **nothing runs today and it costs nothing**. Phase D below is the remaining prerequisite.
- **The plan's shape changed under it:** `message_store.ex` now carries seven relational joins —
  receipt reciprocity (`user_privacy_settings`), the media download oracle
  (`conversation_participants`), stars, poll/receipt aggregates — that are not Scylla-shaped and
  would stay in Postgres. The eventual shape is therefore a **hybrid** (message CRUD in Scylla,
  relational satellites in Postgres), **not a migration**.
- **The trigger is a measurement, not a date:** flip only when `list_messages` latency or Postgres
  write throughput is a profiled bottleneck (the slice-49 standard). Until then the adapter seam is
  the whole point — it keeps the option open at zero carrying cost.

## 9. Dual-write operations (C7)

**The flag:** `MESSAGE_STORE_ADAPTER=dual_write` on the message service. Default is unchanged
(`postgres`) — deploying the C7 code without touching the env changes nothing observable; the dual
adapter is simply never in the call path. Reads never touch Scylla under dual-write; Postgres stays
authoritative for everything.

**Shadow isolation:** mirrors run as detached supervised tasks with 2s per-call timeouts; with the
scylla container stopped (the current production state) each mirror fails in microseconds via the
local process check. Failed mirrors are RECORDED in `scylla_mirror_failures`, not just logged.

**Operator sequence** (remote console on the message service):

```elixir
# 1. after enabling dual_write and bringing scylla up: copy history
MessageService.ScyllaBackfill.run()

# 2. re-drive anything the shadow missed while scylla was flaky
MessageService.ScyllaBackfill.repair_failures()

# 3. THE VERIFICATION REPORT — the C8 gate
MessageService.ScyllaBackfill.report()
```

**The gate for C8:** `stale_diff_total == 0 AND unresolved_failures == 0` on TWO consecutive reports
at least 10 minutes apart, during steady traffic. Rows younger than the 300s in-flight horizon are
excluded (that is lag, not divergence); a diff that appears in both reports with the same message_id
is real — investigate before proceeding. Divergent rows are recopied from authority with
`ScyllaBackfill.recopy(conversation_id, ids)`; convergence under live writes is the verify-then-
recopy discipline (proven by the race test in ScyllaDualWriteTest).

## 10. Phase C / D (still required before Scylla can serve traffic)

**Phase C — missing Scylla-side features.** `MessageStore.ScyllaAdapter` has no equivalent for stars,
polls, media listing, search, or the receipt/reaction aggregates the Postgres adapter provides — the
same satellites the position above keeps in Postgres, which shrinks Phase C to whatever a hybrid
still needs from the adapter itself.

**Phase D — the type/encoding gap (the real blocker).** The write plans supply Elixir terms that do
not match the CQL column types:

| Column | CQL type | What `insert_message_plan` supplies |
|---|---|---|
| `bucket_date` | `date` | an **ISO8601 string** (`"2026-07-31"`) |
| `created_at` / `edited_at` / `deleted_at` | `timestamp` | strings / `DateTime`s |
| `metadata` | `map<text, text>` | an arbitrary map (values may be integers) |
| `message_id` / `reply_to_message_id` | `timeuuid` | hyphenated v1 strings — these are **fine** |
| `conversation_id` / `sender_user_id` / `media_id` | `uuid` | hyphenated strings — **fine** |

Only after that is settled should `MESSAGE_STORE_ADAPTER=scylla` be considered, and only behind a
dual-write/backfill plan: the adapter has never run against a live cluster, and nothing migrates the
existing Postgres data.
