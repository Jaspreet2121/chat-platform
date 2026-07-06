-- Feature: Phase-1 calling (LiveKit) — the `calls` record for call lifecycle + history + missed calls, and
-- (later) to validate LiveKit token requests against a real call row. One row per 1-on-1 call.
--
-- NOTE: this is SEPARATE from the legacy `call_sessions`/`call_participants`/`call_logs` tables (010),
-- which were scaffolding for an earlier NATIVE-WebRTC design (audio/video, started_by + participants, no
-- room_name). The LiveKit approach signals the ring over the user:<id> channel and needs a flat call row
-- with a LiveKit room_name + explicit caller/callee — hence this table. The legacy tables are currently
-- unwritten; reconciling/retiring them is a separate follow-up.
--
-- room_name is UNIQUE (its unique index also serves lookups). caller/callee/conversation are plain uuids
-- (no cross-service FK — user ids originate in auth-service), matching the loosely-coupled service split.
--
-- Idempotent + transactional (fresh initdb volume AND already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../066_calls.sql
BEGIN;

CREATE TABLE IF NOT EXISTS calls (
  id uuid PRIMARY KEY,
  room_name text NOT NULL UNIQUE,
  caller_id uuid NOT NULL,
  callee_id uuid NOT NULL,
  conversation_id uuid,
  type text NOT NULL CHECK (type IN ('voice', 'video')),
  status text NOT NULL DEFAULT 'ringing'
    CHECK (status IN ('ringing', 'accepted', 'declined', 'missed', 'ended')),
  created_at timestamptz NOT NULL DEFAULT now(),
  answered_at timestamptz,
  ended_at timestamptz
);

-- Per-user history lookups (both sides of the call), newest first. room_name is already indexed by its
-- UNIQUE constraint, so no separate room_name index is needed.
CREATE INDEX IF NOT EXISTS idx_calls_caller_id ON calls(caller_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_calls_callee_id ON calls(callee_id, created_at DESC);

COMMIT;
