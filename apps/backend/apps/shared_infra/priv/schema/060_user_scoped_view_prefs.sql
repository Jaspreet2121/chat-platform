-- Feature: user-scoped "clear chat" + "auto-delete messages" (24h / 7d). These are SOFT-HIDES only:
-- both columns live on the CALLER's own conversation_participants row and merely narrow that user's
-- message reads (the store filter applies ONLY when a viewer_user_id is present). Nothing is ever
-- deleted from messages, and the admin content viewer (which passes no viewer_user_id) is never
-- filtered — DB retention and moderation visibility are unchanged.
--
--   cleared_before      — "clear chat": the user's fetches hide messages created at/before this instant.
--   auto_delete_seconds — rolling window: NULL = off, 86400 = 24h, 604800 = 7 days.
--
-- Idempotent + transactional (fresh initdb volume AND already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../060_user_scoped_view_prefs.sql
BEGIN;

ALTER TABLE conversation_participants ADD COLUMN IF NOT EXISTS cleared_before timestamptz;
ALTER TABLE conversation_participants ADD COLUMN IF NOT EXISTS auto_delete_seconds integer;

COMMIT;
