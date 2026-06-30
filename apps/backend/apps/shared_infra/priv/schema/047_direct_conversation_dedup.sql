-- 047: Idempotent direct conversations — exactly one thread per user-pair.
--
-- Adds a canonical `direct_key` (the two participant UUIDs sorted ascending, "min:max") set ONLY for
-- type='direct', collapses any pre-existing duplicate direct threads (keep the OLDEST, repoint its
-- messages), then enforces uniqueness with a PARTIAL UNIQUE INDEX scoped to type='direct'. Groups /
-- business conversations are unaffected (their direct_key stays NULL and the partial predicate excludes
-- them); direct convs that somehow don't have exactly two participants keep a NULL key (NULLs are
-- distinct in a unique index, so they never collide).
--
-- Idempotent (ADD COLUMN / CREATE INDEX IF NOT EXISTS + re-runnable backfill/dedupe) so it applies to
-- BOTH a fresh initdb volume (auto-run) AND an already-running database. To apply to a running stack
-- WITHOUT recreating the volume (so local data is preserved):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -v ON_ERROR_STOP=1 \
--     < infra/docker/postgres/init/047_direct_conversation_dedup.sql

BEGIN;

-- 1) The canonical key column (nullable; only direct convs ever get a value).
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS direct_key text;

-- 2) Backfill: for each direct conversation with exactly two participants, direct_key = "minUUID:maxUUID"
--    (lexical UUID sort via min()/max() over user_id::text — matches the app's sorted-join key).
UPDATE conversations c
SET direct_key = p.k
FROM (
  SELECT conversation_id,
         min(user_id::text) || ':' || max(user_id::text) AS k,
         count(*) AS n
  FROM conversation_participants
  GROUP BY conversation_id
) p
WHERE c.id = p.conversation_id
  AND c.type = 'direct'
  AND p.n = 2;

-- 3) Collapse duplicates BEFORE the unique index (it would fail otherwise). Keep the OLDEST conversation
--    per direct_key; repoint the duplicates' messages onto it; then delete the duplicates (their
--    participant rows drop via ON DELETE CASCADE, and the kept conv already holds the same pair).
WITH ranked AS (
  SELECT id,
         first_value(id) OVER (PARTITION BY direct_key ORDER BY created_at ASC, id ASC) AS keep_id,
         row_number() OVER (PARTITION BY direct_key ORDER BY created_at ASC, id ASC) AS rn
  FROM conversations
  WHERE type = 'direct' AND direct_key IS NOT NULL
),
dupes AS (SELECT id, keep_id FROM ranked WHERE rn > 1)
UPDATE messages m
SET conversation_id = d.keep_id
FROM dupes d
WHERE m.conversation_id = d.id;

WITH ranked AS (
  SELECT id,
         row_number() OVER (PARTITION BY direct_key ORDER BY created_at ASC, id ASC) AS rn
  FROM conversations
  WHERE type = 'direct' AND direct_key IS NOT NULL
)
DELETE FROM conversations
WHERE id IN (SELECT id FROM ranked WHERE rn > 1);

-- 4) Enforce one direct thread per pair. PARTIAL → only type='direct' rows participate.
CREATE UNIQUE INDEX IF NOT EXISTS idx_conversations_direct_key_unique
  ON conversations (direct_key)
  WHERE type = 'direct';

COMMIT;
