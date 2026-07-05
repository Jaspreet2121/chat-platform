-- Feature: "disappearing messages" — extends the existing user-scoped auto-delete (060) with an
-- "After viewing" timing option. Like cleared_before / auto_delete_seconds this is a SOFT-HIDE only:
-- it lives on a conversation_participants row and merely narrows that user's message reads (the store
-- filter applies ONLY when a viewer_user_id is present). Nothing is ever deleted from messages, and the
-- admin content viewer (which passes no viewer_user_id) is never filtered — DB retention and moderation
-- visibility are unchanged.
--
--   disappear_after_viewing — when true, the user's fetches hide messages they've already READ
--                             (message_receipts.read_at IS NOT NULL). NULL/false = off.
--
-- Scope is NOT a column: "my side only" writes the caller's row; "both sides" writes every active
-- participant's row (reusing auto_delete_seconds + this flag), so it hides from everyone's own view.
--
-- Idempotent + transactional (fresh initdb volume AND already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../063_disappearing_after_viewing.sql
BEGIN;

ALTER TABLE conversation_participants
  ADD COLUMN IF NOT EXISTS disappear_after_viewing boolean NOT NULL DEFAULT false;

COMMIT;
