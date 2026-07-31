-- Fix: media-download authorization is now OWNER-ANCHORED — "may this viewer download?" = "is the
-- viewer an active member of ANY conversation containing a message referencing this media_id whose
-- SENDER is the asset's OWNER". That EXISTS needs messages reachable BY media_id; until now the only
-- lookup (get_by_media_id's oldest-wins resolve) scanned unindexed. Partial: media-less rows (the vast
-- majority) stay out of the index.
--
-- Idempotent + transactional (fresh initdb volume AND an already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../083_messages_media_index.sql
BEGIN;

CREATE INDEX IF NOT EXISTS idx_messages_media_id
  ON messages (media_id) WHERE media_id IS NOT NULL;

COMMIT;
