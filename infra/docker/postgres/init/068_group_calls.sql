-- Feature: Phase-3 group calling (Slice A1) — extend the LIVE `calls` table + `conversation_settings` for
-- group calls. ADDITIVE + fully guarded so re-running is a no-op on a table that already holds 1-on-1 rows:
--   * calls.kind ('direct'|'group', DEFAULT 'direct' → every existing row stays a 1-on-1 call)
--   * calls.callee_id becomes NULLABLE (a group call has no single callee; 1-on-1 keeps it set)
--   * calls.status gains 'ongoing' (a group call in progress, ≥1 participant joined)
--   * conversation_settings.call_start_permission ('everyone'|'admins_only', DEFAULT 'everyone')
--
-- Guarded with IF NOT EXISTS / DROP CONSTRAINT IF EXISTS + ADD so it is safe to re-run.
BEGIN;

-- calls.kind + guarded check.
ALTER TABLE calls ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'direct';
ALTER TABLE calls DROP CONSTRAINT IF EXISTS calls_kind_check;
ALTER TABLE calls ADD CONSTRAINT calls_kind_check CHECK (kind IN ('direct', 'group'));

-- Group calls carry NULL callee_id. Idempotent — DROP NOT NULL is a no-op if the column is already nullable.
ALTER TABLE calls ALTER COLUMN callee_id DROP NOT NULL;

-- Extend the status check to include 'ongoing' (drop the 066 inline check, re-add with the extra value).
ALTER TABLE calls DROP CONSTRAINT IF EXISTS calls_status_check;
ALTER TABLE calls ADD CONSTRAINT calls_status_check
  CHECK (status IN ('ringing', 'accepted', 'declined', 'missed', 'ended', 'ongoing'));

-- conversation_settings.call_start_permission + guarded check (mirrors the boolean flags already here).
ALTER TABLE conversation_settings
  ADD COLUMN IF NOT EXISTS call_start_permission text NOT NULL DEFAULT 'everyone';
ALTER TABLE conversation_settings DROP CONSTRAINT IF EXISTS conversation_settings_call_start_permission_check;
ALTER TABLE conversation_settings ADD CONSTRAINT conversation_settings_call_start_permission_check
  CHECK (call_start_permission IN ('everyone', 'admins_only'));

COMMIT;
