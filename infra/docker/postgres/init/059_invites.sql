-- Feature: WhatsApp-style invites. When a searched phone number is not on the platform, the user can
-- send a pre-filled WhatsApp/SMS invite (device URL schemes — no send API). This table only RECORDS the
-- generated invite codes (inviter + invited phone) so invites are stable (same code re-offered for the
-- same pair) and acceptance can be tracked later; sending happens entirely on the inviter's device.
--
-- Idempotent + transactional (fresh initdb volume AND already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../059_invites.sql
BEGIN;

CREATE TABLE IF NOT EXISTS invites (
  code             text PRIMARY KEY,
  inviter_user_id  uuid NOT NULL,
  invited_phone    text NOT NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  accepted_at      timestamptz
);

-- One pending (not-yet-accepted) invite per inviter+phone pair: create_invite reuses it.
CREATE UNIQUE INDEX IF NOT EXISTS invites_pending_pair_idx
  ON invites (inviter_user_id, invited_phone)
  WHERE accepted_at IS NULL;

-- Acceptance lookup by phone (mark accepted when the invited number signs up later).
CREATE INDEX IF NOT EXISTS invites_invited_phone_idx ON invites (invited_phone);

COMMIT;
