-- Feature 131: GROUP-CALL RING TIMESTAMPS — two additive columns on group_call_participants.
--
-- The per-participant state for a group call already lives on this table (067): invited / joined /
-- declined / left / missed, with joined_at and left_at. Two moments were never recorded, and the
-- group push (130-group) needs both:
--
--   rung_at      — when THIS member's ring was emitted. Set on create for every invitee, and RESET when
--                  a declined/left/missed member is re-invited (add_call_participant), because the
--                  ring deadline the push carries (rung_at + the 35 s ring window) must start again for
--                  the new ring, not the first one. The initiator is seated joined and is never rung, so
--                  its rung_at stays NULL — which is also how "was this row ever rung" is asked.
--   declined_at  — when the member declined. Idempotency for the REST decline (a second decline is a
--                  200 that writes nothing) and the fact the reaper and history read.
--
-- Both nullable, no backfill: a row from before this migration simply has no ring time, and every
-- reader treats NULL as "unknown", never as "now". Re-runnable: ADD COLUMN IF NOT EXISTS.

ALTER TABLE group_call_participants ADD COLUMN IF NOT EXISTS rung_at timestamptz;
ALTER TABLE group_call_participants ADD COLUMN IF NOT EXISTS declined_at timestamptz;

-- The reaper's read: still-ringing group/adhoc calls older than the ring window. `calls` already has
-- (status) reads; this narrows them to the two kinds the reaper may touch, so a direct call's own
-- timer path is never second-guessed by it.
CREATE INDEX IF NOT EXISTS idx_calls_ringing_group_created
  ON calls (created_at)
  WHERE status = 'ringing' AND kind IN ('group', 'adhoc');
