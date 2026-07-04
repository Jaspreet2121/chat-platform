-- Group avatars: group_profiles has avatar_media_id but presigning a download URL also needs the
-- storage object_key (a viewer can't reconstruct another entity's key — same as user avatars, which
-- carry both avatar_media_id AND avatar_object_key). Add it so group photos can be presigned/shown.
--
-- Idempotent + transactional (fresh initdb volume AND already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../062_group_avatar_object_key.sql
BEGIN;

ALTER TABLE group_profiles ADD COLUMN IF NOT EXISTS avatar_object_key text;

COMMIT;
