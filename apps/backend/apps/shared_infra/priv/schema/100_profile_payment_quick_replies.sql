-- Feature: slash commands + UPI payment QR on the profile (100, 2026-08-18).
--
--   * user_profiles payment/business columns — all optional. upi_id/payment_name come from a SCANNED
--     upi:// payload (or manual entry); upi_merchant is the jsonb passthrough of every other scanned
--     param (mc, tr, tn, mode, purpose, orgid, sign, ...) so the regenerated QR stays functionally
--     identical to the original; upi_qr_media_id points at the server-generated 512px QR PNG (a
--     regular user-owned media asset, so it can be attached/forwarded like any image).
--   * profile_visibility jsonb: {"payment": "everyone"|"contacts"|"nobody" (default contacts),
--     "business": "everyone"|"nobody" (default everyone)} — enforced in the gateway presenter,
--     exactly like profile_photo_visibility. Defaults applied at read (missing key = default).
--   * quick_replies — per-user, APP-SCOPED custom /shortcuts. shortcut ^[a-z0-9_]{1,25}$, unique per
--     user, max 50 (enforced in code), body <= 1000, optional media the user owns.
--
-- Idempotent + transactional (fresh initdb volume AND an already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../100_profile_payment_quick_replies.sql
BEGIN;

ALTER TABLE user_profiles ADD COLUMN IF NOT EXISTS upi_id text;
ALTER TABLE user_profiles ADD COLUMN IF NOT EXISTS payment_name text;
ALTER TABLE user_profiles ADD COLUMN IF NOT EXISTS upi_merchant jsonb;
ALTER TABLE user_profiles ADD COLUMN IF NOT EXISTS upi_qr_media_id uuid;
ALTER TABLE user_profiles ADD COLUMN IF NOT EXISTS address text;
ALTER TABLE user_profiles ADD COLUMN IF NOT EXISTS website text;
ALTER TABLE user_profiles ADD COLUMN IF NOT EXISTS business_email text;
ALTER TABLE user_profiles ADD COLUMN IF NOT EXISTS business_hours text;
ALTER TABLE user_profiles ADD COLUMN IF NOT EXISTS profile_visibility jsonb NOT NULL DEFAULT '{}'::jsonb;

CREATE TABLE IF NOT EXISTS quick_replies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id uuid NOT NULL,
  user_id uuid NOT NULL REFERENCES users_auth(id) ON DELETE CASCADE,
  shortcut text NOT NULL,
  body text NOT NULL,
  media_id uuid,
  position integer NOT NULL DEFAULT 0,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS quick_replies_user_shortcut ON quick_replies (user_id, shortcut);
CREATE INDEX IF NOT EXISTS idx_quick_replies_user ON quick_replies (user_id, position);

COMMIT;
