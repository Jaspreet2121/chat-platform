-- 110: sealed_media purpose (Secret chats v2, 109). An E2EE attachment is uploaded already
-- CIPHERTEXT (encrypted client-side per E2EE_FRAME.md §media); the server stores + serves the bytes
-- OPAQUELY — no thumbnail, no content sniff, no transform (none exist for any purpose today; the
-- media service only presigns S3/MinIO). This purpose joins the CHECK set so a sealed attachment
-- can be uploaded; its download ACL is identical to a normal message attachment (conversation
-- membership).
--
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../110_sealed_media_purpose.sql
BEGIN;

ALTER TABLE media_assets DROP CONSTRAINT IF EXISTS media_assets_purpose_check;
ALTER TABLE media_assets ADD CONSTRAINT media_assets_purpose_check
  CHECK (purpose IN ('message', 'user_avatar', 'group_avatar', 'status', 'sealed_media'));

COMMIT;
