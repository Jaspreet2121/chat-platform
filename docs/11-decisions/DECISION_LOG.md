# Decision Log

Architecture decisions, newest first. Each entry: context → decision → rationale → status.

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
