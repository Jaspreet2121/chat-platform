-- Feature: Phase-3 group calling — per-participant membership of a call (Slice A1, data foundation only).
-- One row per (call, user): who was invited/joined and their per-member join state. A 1-on-1 call keeps
-- working WITHOUT any rows here — participant rows are GROUP-only; the flat `calls` row (066) still holds
-- the call + its LiveKit room for both direct and group.
--
-- Same-service FK to calls(id) ON DELETE CASCADE (both tables live in conversation_service). user_id is a
-- plain uuid (originates in auth-service — no cross-service FK), matching repo convention.
--
-- Idempotent + transactional (fresh initdb volume AND an already-running database with 1-on-1 call rows).
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../067_call_participants.sql
BEGIN;

CREATE TABLE IF NOT EXISTS call_participants (
  call_id uuid NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
  user_id uuid NOT NULL,
  status text NOT NULL DEFAULT 'invited'
    CHECK (status IN ('invited', 'joined', 'declined', 'left', 'missed')),
  joined_at timestamptz,
  left_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (call_id, user_id)
);

-- Per-user history lookups (calls a user was invited to / joined), newest first.
CREATE INDEX IF NOT EXISTS idx_call_participants_user ON call_participants(user_id, created_at DESC);

COMMIT;
