-- Feature: FCM push tokens (Phase 2, Android) — the device-token store for the Firebase Cloud
-- Messaging delivery leg, mirroring push_subscriptions (061) exactly.
--
-- One row per Android app INSTALLATION. The FCM registration token is globally unique and is the
-- conflict target: re-registering the same token updates its owner/device, so a device that gets
-- re-signed-in MOVES to the new account rather than double-delivering to the old one. Owned by the
-- auth service (a token is a device credential); the notification service READS it to deliver and
-- DELETES rows FCM reports as dead (UNREGISTERED/INVALID_ARGUMENT). ON DELETE CASCADE with the
-- account, exactly like push_subscriptions.
--
-- `platform` is a column rather than an assumption: web-push covers browsers today and iOS would be
-- another value here, not another table.
--
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../074_fcm_tokens.sql
BEGIN;

CREATE TABLE IF NOT EXISTS fcm_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users_auth(id) ON DELETE CASCADE,
  token text NOT NULL UNIQUE,
  device_id text,
  platform text NOT NULL DEFAULT 'android',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- The delivery lookup: every token for a recipient (the fan-out reads this per push).
CREATE INDEX IF NOT EXISTS fcm_tokens_user_idx ON fcm_tokens (user_id);

COMMIT;
