-- Backfill media_assets (Phase 6) so the Phase-2 read path can authorize EXISTING media by a real row.
-- Before this, media_assets had 1 row (the single live upload); 23 messages carry a media_id and 3 user
-- profiles carry an avatar_object_key, all invisible to the row-based read path. This inserts the missing
-- rows from the authoritative sources (messages.metadata, *_profiles.avatar_object_key).
--
-- app_id for message media = the PARENT CONVERSATION's app_id (conversations.app_id), NOT messages.app_id
-- (unreliable). Rows without an object_key are skipped (never insert garbage). media_assets has
-- UNIQUE (bucket, object_key) + a pkey on id, so every insert is ON CONFLICT DO NOTHING — safe to re-run and
-- can't collide with the 1 pre-existing row. bucket/storage_provider match the MinIO config (chat-media / minio).
--
-- Idempotent + transactional (fresh initdb volume AND already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../073_backfill_media_assets.sql
BEGIN;

-- 1) MESSAGE MEDIA — one media_assets row per message carrying a media_id + an object_key.
INSERT INTO media_assets (
  id, owner_user_id, conversation_id, app_id, purpose,
  storage_provider, bucket, object_key, mime_type, size_bytes, status
)
SELECT
  m.media_id,
  m.sender_user_id,
  m.conversation_id,
  c.app_id,
  'message',
  'minio',
  'chat-media',
  m.metadata->>'object_key',
  COALESCE(NULLIF(m.metadata->>'content_type', ''), 'application/octet-stream'),
  CASE WHEN m.metadata->>'size_bytes' ~ '^[0-9]+$' THEN (m.metadata->>'size_bytes')::bigint ELSE 0 END,
  'ready'
FROM messages m
JOIN conversations c ON c.id = m.conversation_id
WHERE m.media_id IS NOT NULL
  AND m.metadata->>'object_key' IS NOT NULL
ON CONFLICT DO NOTHING;

-- 2) USER AVATARS — one row per profile with an avatar_object_key. If the profile had no avatar_media_id,
-- mint one and point the profile at it (so the read path can resolve the avatar by media_id).
DO $$
DECLARE r RECORD; new_id uuid;
BEGIN
  FOR r IN
    SELECT user_id, app_id, avatar_object_key, avatar_media_id
    FROM user_profiles
    WHERE avatar_object_key IS NOT NULL
  LOOP
    new_id := COALESCE(r.avatar_media_id, gen_random_uuid());
    INSERT INTO media_assets (
      id, owner_user_id, conversation_id, app_id, purpose,
      storage_provider, bucket, object_key, mime_type, size_bytes, status
    )
    VALUES (
      new_id, r.user_id, NULL, r.app_id, 'user_avatar',
      'minio', 'chat-media', r.avatar_object_key, 'application/octet-stream', 0, 'ready'
    )
    ON CONFLICT DO NOTHING;

    IF r.avatar_media_id IS NULL THEN
      UPDATE user_profiles SET avatar_media_id = new_id, updated_at = now() WHERE user_id = r.user_id;
    END IF;
  END LOOP;
END $$;

-- 3) GROUP AVATARS — group_profiles.avatar_object_key exists (migration 062). owner = the conversation's
-- creator; app_id + conversation_id from the parent conversation. (0 rows is fine — idempotent.)
DO $$
DECLARE r RECORD; new_id uuid;
BEGIN
  FOR r IN
    SELECT gp.conversation_id, gp.avatar_object_key, gp.avatar_media_id, c.app_id, c.created_by
    FROM group_profiles gp
    JOIN conversations c ON c.id = gp.conversation_id
    WHERE gp.avatar_object_key IS NOT NULL
  LOOP
    new_id := COALESCE(r.avatar_media_id, gen_random_uuid());
    INSERT INTO media_assets (
      id, owner_user_id, conversation_id, app_id, purpose,
      storage_provider, bucket, object_key, mime_type, size_bytes, status
    )
    VALUES (
      new_id, r.created_by, r.conversation_id, r.app_id, 'group_avatar',
      'minio', 'chat-media', r.avatar_object_key, 'application/octet-stream', 0, 'ready'
    )
    ON CONFLICT DO NOTHING;

    IF r.avatar_media_id IS NULL THEN
      UPDATE group_profiles SET avatar_media_id = new_id, updated_at = now() WHERE conversation_id = r.conversation_id;
    END IF;
  END LOOP;
END $$;

COMMIT;

-- Operator eyeball (expected ≈ 1 pre-existing + 23 message + 3 user-avatar + N group-avatar rows):
SELECT purpose, count(*) FROM media_assets GROUP BY purpose ORDER BY purpose;
SELECT count(*) AS media_assets_total FROM media_assets;
