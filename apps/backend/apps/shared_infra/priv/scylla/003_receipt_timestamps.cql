-- C4 contact-point fix: message_info's reciprocity contract needs BOTH timestamps preserved through
-- the delivered -> read upgrade (the Postgres row keeps delivered_at when read_at lands; the wire
-- shows the true delivered time even for read messages). A single (status, updated_at) pair loses
-- delivered_at on the read upsert. CQL column-level upserts preserve unset columns, so a
-- status-specific write (delivered writes delivered_at; read writes read_at) merges into one row
-- with both — exactly the Postgres semantics — once the columns exist.
--
-- IDEMPOTENCY, verified against the live engine: Scylla 5.4 REJECTS `ALTER ... ADD IF NOT EXISTS`
-- (SyntaxException — tried, not assumed). So this file is NOT self-idempotent; the loader
-- (scripts/test-scylla.sh, and the prod runbook) treats "conflicts with an existing column" as
-- already-applied. Every other .cql here stays fully IF NOT EXISTS; keep ALTERs isolated in their
-- own numbered files so the tolerance stays narrow.

USE chat_messages;

ALTER TABLE message_receipts_by_conversation ADD delivered_at timestamp;
ALTER TABLE message_receipts_by_conversation ADD read_at timestamp;
