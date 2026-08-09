-- 096: kafka_event_outbox — durable intent for message.events.v1 publishes (the C6 pattern
-- applied to Kafka; DECISION_LOG design 2026-08-09/10).
--
-- Fire-and-forget publish lost events silently: {:ok, :produced} from brod is BUFFER-ACCEPT, not
-- delivery, so a broker outage after accept lost the event with no log — and a lost event never
-- writes a consumer ledger row, so nothing ever retried. A lost create loses the push, the
-- notification rows, the summary, the inbox increment+preview and the search row; a lost delete
-- loses the preview promotion, the settle-claim decrement, the search DELETE and the pin DELETE.
--
-- The row is the event's existence: STAGED in the same Postgres transaction as the webhook intent
-- (create path) or before the tombstone (delete path), PROMOTED to pending after the Scylla write,
-- DELETED on broker-acked publish (produce_sync), ABORTED (kept, with last_error, as evidence)
-- when the store write failed. The relay moves pending/stale-staged rows forward exactly once —
-- a one-way state machine, never a recompute; every crash window lands on DUPLICATED (absorbed by
-- the consumers' ledgers), never on LOST. Loss now requires losing Postgres durability itself.
--
-- DEPLOY ORDER — HARSHER THAN THE 42P01-RETRY PATTERN. No consumer reads this table, but the
-- STAGE INSERT runs inside the message-create transaction: code-before-migration makes EVERY
-- MESSAGE SEND FAIL with Postgrex.Error on the hottest path in the app. Apply this file FIRST,
-- then deploy. (CREATE TABLE IF NOT EXISTS + an index on a new empty table: no ALTER, no locks on
-- hot tables, idempotent — safe to apply any time before the deploy.)
--
-- conversation_id + message_id are the sweeper's store-check key (is the message real?);
-- event_type decides what "real" must mean (created: exists; deleted: tombstoned).
CREATE TABLE IF NOT EXISTS kafka_event_outbox (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  topic           text        NOT NULL,
  partition_key   text        NOT NULL,
  event_type      text        NOT NULL,
  envelope        jsonb       NOT NULL,
  conversation_id uuid        NOT NULL,
  message_id      uuid        NOT NULL,
  status          text        NOT NULL DEFAULT 'staged',
  attempts        int         NOT NULL DEFAULT 0,
  last_error      text,
  created_at      timestamptz NOT NULL DEFAULT now()
);

-- The relay's scan: work rows by state, oldest first. Published rows are DELETED (transient
-- intent, no read value), so the table holds only in-flight and aborted-evidence rows.
CREATE INDEX IF NOT EXISTS kafka_event_outbox_status_idx
  ON kafka_event_outbox (status, created_at);
