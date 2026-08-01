-- Fix: 'status' joins the media purpose set — the SECOND layer of the same gap. The status media
-- authz arm (e4189ce) shipped while BOTH the upload whitelist (media.ex fetch_purpose) and this
-- CHECK constraint were never told the purpose existed: photo/video status could not be uploaded at
-- any layer, while every status test fabricated media ids that no upload could have produced. The
-- whitelist-enumeration test in MediaService.MediaTest now creates through the REAL path for every
-- purpose, so a purpose missing at either layer fails the gate instead of shipping.
--
-- Idempotent + transactional:
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../089_media_purpose_status.sql
BEGIN;

ALTER TABLE media_assets DROP CONSTRAINT IF EXISTS media_assets_purpose_check;
ALTER TABLE media_assets ADD CONSTRAINT media_assets_purpose_check
  CHECK (purpose IN ('message', 'user_avatar', 'group_avatar', 'status'));

COMMIT;
