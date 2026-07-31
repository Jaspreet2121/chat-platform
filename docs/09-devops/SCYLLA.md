# ScyllaDB — Phase A (container + schema)

**Status: groundwork only. Scylla serves NO reads or writes.** Postgres remains the message store.
This phase brings the container up and loads the CQL schema so Phase B has something to connect to.

What Phase A deliberately does **not** do:

- does **not** change `MESSAGE_STORE_ADAPTER` (still `postgres` everywhere);
- does **not** add a driver dependency (no Xandra) — `SharedInfra.Scylla.Client`'s default adapter
  still returns `:scylla_unavailable`, so even with the container up nothing can talk to it;
- does **not** add `depends_on: scylla` to any service — nothing can fail because Scylla is absent;
- does **not** touch existing message data, or the CQL schema's key/table design.

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
ports, health-gated). Verify the tag pulls on the target host before a real deploy; align the two when
Phase B lands.

---

## 6. Config wiring

`config/runtime.exs` reads two env vars, **gated so that absence writes no config at all**:

| Env | Default when the block runs | Effect |
|---|---|---|
| `SCYLLA_NODES` | *(gates the block — unset means nothing is configured)* | `"scylla:9042"`, or a comma list `"a:9042,b:9043"`. A bare host defaults to port 9042. Parsed into the `{host, port}` tuples `SharedInfra.Config.Scylla` expects. |
| `SCYLLA_KEYSPACE` | `chat_messages` | Keyspace name. |

**No service currently sets `SCYLLA_NODES`.** That is intentional for Phase A: adding it to the message
service's environment would recreate that container for a value nothing reads. Phase B sets it (along
with the driver) as part of the same change that makes it meaningful.

---

## 7. Phase B (required before Scylla can serve anything)

1. A real CQL driver (Xandra) behind `SharedInfra.Scylla.Client` — today's default adapter returns
   `:scylla_unavailable`, so the container is inert no matter what is configured.
2. Set `SCYLLA_NODES` (and `SCYLLA_KEYSPACE` if not the default) on the message service.
3. Only then consider `MESSAGE_STORE_ADAPTER=scylla`, and only behind a dual-write/backfill plan —
   `MessageStore.ScyllaAdapter` has never run against a live cluster, and the existing Postgres data is
   not migrated by anything in this phase.
