-- Feature: LEAVE GROUP — distinguish a VOLUNTARY leave from an owner/admin REMOVAL on
-- conversation_participants. Until now left_at had exactly one writer (the moderation remove path), so
-- left_at ≡ removed; the new first-party leave endpoint breaks that equivalence, and the invite-link
-- rejoin rule (077) needs the distinction: a REMOVED user is refused by a live link, a voluntary LEAVER
-- may rejoin (reactivation).
--
--   left_reason — NULL while the row is active. 'removed' = taken out by the owner/an admin;
--                 'left' = left voluntarily via POST /:conversation_id/leave.
--
-- Backfill: every pre-existing left row was written by the moderation path (verified: no other writer of
-- left_at exists before this feature), so they are all 'removed'.
--
-- Idempotent + transactional (fresh initdb volume AND an already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../078_leave_group.sql
BEGIN;

ALTER TABLE conversation_participants
  ADD COLUMN IF NOT EXISTS left_reason text CHECK (left_reason IN ('left', 'removed'));

UPDATE conversation_participants SET left_reason = 'removed'
  WHERE left_at IS NOT NULL AND left_reason IS NULL;

COMMIT;
