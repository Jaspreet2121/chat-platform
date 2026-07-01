-- 056: Make messages.app_id AUTHORITATIVE (defuse the tenant-zero landmine).
--
-- Migration 048 added messages.app_id with a DB DEFAULT of the tenant-zero app and inserts never set it,
-- so every message row wrongly carried 0000…0001. Nothing scoped on it (tenancy is enforced via the
-- conversation), but a future `WHERE messages.app_id = …` would silently mis-scope. This corrects it:
--   a) BACKFILL each message's app_id from its conversation (only where they differ → no-op on re-run).
--   b) DROP the tenant-zero DEFAULT so no future insert can silently inherit it (the app code now sets
--      app_id explicitly from the conversation on insert — see MessageStore.PostgresAdapter.put_message).
--   c) Keep NOT NULL (already set by 048; re-asserted here, AFTER backfill).
-- Order matters: backfill FIRST, then drop default, then ensure NOT NULL — never enforce before backfill.
--
-- The conversation gate REMAINS the enforcing authority; this just makes messages.app_id a reliable
-- second layer (defense-in-depth). Reads are unchanged — nothing is switched to scope on this column.
--
-- SCALE NOTE: dev volume is tiny so the backfill is a single UPDATE. At prod scale, batch it (e.g.
-- UPDATE … WHERE message_id IN (SELECT … LIMIT N) looped, or by created_at windows) to avoid a long
-- lock on the messages table; the DROP DEFAULT / NOT NULL steps are metadata-only and fast.
--
-- Idempotent + transactional (fresh initdb volume AND a running DB):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -v ON_ERROR_STOP=1 \
--     < infra/docker/postgres/init/056_messages_app_id_authoritative.sql

BEGIN;

-- a) Correct existing rows: app_id := parent conversation's app_id. Only rows that differ (no-op re-run).
--    Orphan messages (no matching conversation) are left as-is — there is no conversation to attribute.
UPDATE messages m
SET app_id = c.app_id
FROM conversations c
WHERE c.id = m.conversation_id
  AND m.app_id <> c.app_id;

-- b) No future insert may silently inherit tenant-zero — the app now sets app_id explicitly.
ALTER TABLE messages ALTER COLUMN app_id DROP DEFAULT;

-- c) Re-assert NOT NULL (already set by 048) now that every row is backfilled.
ALTER TABLE messages ALTER COLUMN app_id SET NOT NULL;

COMMIT;
