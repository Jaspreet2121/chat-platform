-- Media tenant + purpose (Phase 0+1 of the media authorization hardening). media_assets is well-designed
-- but has no tenant column and can't distinguish a message attachment from an avatar. The write path
-- (create_upload/complete_upload) now persists rows here so the read path (Phase 2) can authorize a
-- download against a REAL record instead of a client-supplied object_key. Adds:
--   * app_id      — tenant scope (mirrors user_profiles.app_id); the read path will do an (app_id, id) lookup.
--   * purpose     — 'message' | 'user_avatar' | 'group_avatar' (conversation_id alone can't tell a group
--                   avatar from a message attachment).
--   * (app_id, id) index — the tenant-scoped lookup Phase 2 will use.
-- The table is empty (0 rows in prod), so the DEFAULTs are cosmetic; kept for the dual-write init path.
--
-- Idempotent + transactional (fresh initdb volume AND already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../072_media_assets_tenant_purpose.sql
BEGIN;

ALTER TABLE media_assets
  ADD COLUMN IF NOT EXISTS app_id uuid NOT NULL
    DEFAULT '00000000-0000-0000-0000-000000000001' REFERENCES apps(id);

ALTER TABLE media_assets
  ADD COLUMN IF NOT EXISTS purpose text NOT NULL DEFAULT 'message';

-- Add the CHECK separately + idempotently (ADD COLUMN can't IF NOT EXISTS a named constraint).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'media_assets_purpose_check'
  ) THEN
    ALTER TABLE media_assets
      ADD CONSTRAINT media_assets_purpose_check
      CHECK (purpose IN ('message', 'user_avatar', 'group_avatar'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_media_assets_app_id_id ON media_assets(app_id, id);

COMMIT;
