-- Feature: Call links L3a — approval gate. When a link has require_approval=true, a non-host joiner waits in
-- 'pending_approval' (no LiveKit token) until the host approves; approval flips the row to 'joined' (deny
-- deletes the row). This ADDS 'pending_approval' to the group_call_participants.status CHECK.
--
-- Direct/group calls are UNAFFECTED — their participant rows are only invited/joined/declined/left/missed,
-- never pending. Idempotent + guarded (drop the 067 inline check by its auto name, re-add with the extra
-- value).
--
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../070_call_link_approval.sql
BEGIN;

ALTER TABLE group_call_participants DROP CONSTRAINT IF EXISTS group_call_participants_status_check;
ALTER TABLE group_call_participants ADD CONSTRAINT group_call_participants_status_check
  CHECK (status IN ('invited', 'joined', 'declined', 'left', 'missed', 'pending_approval'));

COMMIT;
