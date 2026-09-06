-- 118: Per-DM E2EE toggle — two-party OFF with consent, and the explicit-disabled marker.
--
-- Turning encryption ON stays as 108 left it: either participant, immediate. Turning it OFF is
-- TWO-PARTY: one member requests, the OTHER member's own OFF is the acceptance, and only that second
-- call flips `secret`. A single-sided OFF never changes the flag — the recorded reason in
-- ConversationService.Encryption still stands (a one-way downgrade is a content-exposure attack
-- surface); what 118 adds is that BOTH parties consenting is not one-way.
--
-- Three nullable columns on `conversations`, NULL for every existing row (no backfill):
--
--   e2ee_disabled_at      — stamped when an OFF is accepted; cleared by the next ON. The client-side
--                           opportunistic upgrade (109 §9 ii) reads this as "explicitly turned off"
--                           and leaves the chat alone instead of re-enabling it on open.
--   e2ee_off_requested_by — the member whose OFF request is pending (NULL = none), and when. At most
--   e2ee_off_requested_at   ONE request per conversation by construction: the other member's own OFF
--                           is the acceptance, never a second request. A request older than 7 days is
--                           treated as absent and cleared on the next read; ON clears it as well.
--
-- Columns, not a table: a DM has exactly two parties, so "pending" is one (who, when) pair that lives
-- on the same row as the flag — a single SELECT ... FOR UPDATE serialises the whole decision, expiry
-- is a predicate on requested_at, and there is nothing to garbage-collect.
--
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../118_e2ee_off_consent.sql
BEGIN;

ALTER TABLE conversations ADD COLUMN IF NOT EXISTS e2ee_disabled_at timestamptz;
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS e2ee_off_requested_by uuid;
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS e2ee_off_requested_at timestamptz;

COMMIT;
