-- Feature: calls carry their tenant + a distinct caller-cancel status (2026-08-16 calls diagnosis).
--
--   * calls.app_id (nullable uuid): the session/credential tenant, stamped at the boundary on every NEW
--     call write. Pre-existing rows stay NULL — they were written before stamping existed and are already
--     tenant-safe (caller_id/callee_id are app-scoped user uuids, so a foreign tenant's user id can never
--     match); the history query treats NULL as "legacy, matched by user id" rather than hiding old history.
--     No FK (user/app ids originate in auth-service — matches the loosely-coupled split, same as caller_id).
--   * calls.status gains 'cancelled': the CALLER hung up while it was still ringing. Previously folded into
--     'missed'; the Calls tab can now tell the caller "Cancelled" while the callee still reads "Missed"
--     (the same masking philosophy as declined-reads-missed-for-the-caller, in the other direction).
--
-- No new index: history reads ride the existing per-user (caller_id/callee_id, created_at DESC) indexes;
-- the app_id predicate is a residual filter on already-user-selective rows.
--
-- Idempotent + transactional (fresh initdb volume AND already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../097_calls_app_id_cancelled.sql
BEGIN;

ALTER TABLE calls ADD COLUMN IF NOT EXISTS app_id uuid;

-- Extend the status check (068 pattern: drop + re-add with the extra value).
ALTER TABLE calls DROP CONSTRAINT IF EXISTS calls_status_check;
ALTER TABLE calls ADD CONSTRAINT calls_status_check
  CHECK (status IN ('ringing', 'accepted', 'declined', 'missed', 'ended', 'ongoing', 'cancelled'));

COMMIT;
