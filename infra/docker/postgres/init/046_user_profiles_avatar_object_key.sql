-- Avatar object key on the profile: store the uploaded avatar's storage object_key alongside
-- avatar_media_id, so the gateway can presign a cross-user avatar download URL (avatar_media_id alone
-- isn't enough — presigning needs the object_key, and a viewer can't reconstruct another user's key).
--
-- Idempotent (ADD COLUMN IF NOT EXISTS) so it applies to BOTH a fresh initdb volume (auto-run) AND an
-- already-running database (run it manually to avoid recreating the volume / losing local data):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -c \
--     "ALTER TABLE user_profiles ADD COLUMN IF NOT EXISTS avatar_object_key text;"
ALTER TABLE user_profiles ADD COLUMN IF NOT EXISTS avatar_object_key text;
