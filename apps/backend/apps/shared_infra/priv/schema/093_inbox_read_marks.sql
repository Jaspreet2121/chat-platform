-- 093: inbox read marks — the exactly-once gate for the unread DECREMENT under the Scylla store.
--
-- WHY THIS EXISTS. Under MESSAGE_STORE_ADAPTER=scylla the unread counter only ever went UP. Every
-- in-transaction maintenance call (record_read, record_delete) lives inside
-- MessageStore.PostgresAdapter and ScyllaAdapter never calls InboxProjection at all, so nothing
-- decremented; the inbox reconciler was the only downward force and it recomputed from a frozen
-- Postgres `messages` table, so it was wrong. It is now correctly gated (interlock in
-- ConversationService.InboxCounters), which left the counter monotonically increasing.
--
-- A decrement is not naturally idempotent: process one read receipt twice and the count is wrong,
-- permanently, because nothing recounts any more. Under Postgres the gate was free — the receipt
-- upsert could see whether a row already existed, in the same transaction. Scylla's receipt write is
-- a blind CQL upsert that reports nothing about prior state, and making it report would mean an LWT
-- (a Paxos round per receipt), which InboxProjection's moduledoc already rejected.
--
-- So the claim is made HERE: INSERT ... ON CONFLICT DO NOTHING, and the decrement runs only when the
-- insert actually claimed the row, both in one transaction. The primary key IS the idempotency.
--
-- IT ALSO ORDERS THE PAIR. The increment is asynchronous (the Kafka inbox projection), so a fast
-- reader can be marked read BEFORE the increment for that message is applied. Without this table the
-- decrement would floor at 0 and the later increment would leave a permanent phantom unread. The
-- increment in InboxProjection.record_message/1 therefore consults these rows too and skips any
-- participant who has already read the message — which makes read-then-increment and
-- increment-then-read converge on the same value.
--
-- RETENTION: unbounded today, one row per (message, reader) actually read. Pruning is NOT safe to
-- add naively — a client re-sending old read receipts after its marks were pruned would decrement a
-- second time and hide genuinely unread messages. `message_created_at` is stored so a future prune
-- can pair a horizon with a matching "ignore reads older than the horizon" rule in the decrement.
CREATE TABLE IF NOT EXISTS inbox_read_marks (
  conversation_id    uuid        NOT NULL,
  message_id         uuid        NOT NULL,
  user_id            uuid        NOT NULL,
  message_created_at timestamptz,
  marked_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (conversation_id, message_id, user_id)
);

-- The increment's per-participant lookup is (conversation_id, message_id, user_id) — a prefix of the
-- primary key, so it needs no second index. This one is for the retention sweep described above.
CREATE INDEX IF NOT EXISTS inbox_read_marks_marked_at_idx ON inbox_read_marks (marked_at);
