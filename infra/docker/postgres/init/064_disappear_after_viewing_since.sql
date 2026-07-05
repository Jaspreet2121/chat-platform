-- Fix: "After viewing" disappearing must only affect messages sent AFTER it was enabled (not old,
-- already-read history). Record WHEN it was turned on. Like 063 this is a SOFT-HIDE input only — it lives
-- on a conversation_participants row and merely narrows that user's reads; nothing is deleted, and the
-- admin content viewer (no viewer_user_id) is never filtered.
--
--   disappear_after_viewing_since — timestamptz set to now() when "After viewing" is enabled, NULL when
--   off. The read filter hides a message only when created_at > this instant AND the viewer has seen it
--   (their own sent messages count as seen; the peer's count once read via message_receipts.read_at).
--
-- Idempotent + transactional (fresh initdb volume AND already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../064_disappear_after_viewing_since.sql
BEGIN;

ALTER TABLE conversation_participants
  ADD COLUMN IF NOT EXISTS disappear_after_viewing_since timestamptz;

COMMIT;
