-- 124: server-side image variants on media_assets.
--
-- `variants` records the derivatives media-service generates for a PLAIN image asset — on complete
-- (MediaService.Variants, synchronously, so the message attached a moment later can carry
-- thumb_url) and by the backfill (MediaService.Variants.Backfill) for assets uploaded before this:
--
--   {"thumb":  {"key": "<object_key>.thumb.jpg",  "w": 256,  "h": 192, "bytes": 2408},
--    "medium": {"key": "<object_key>.medium.jpg", "w": 1280, "h": 960, "bytes": 376724}}
--
-- NULL      = nothing generated yet (never eligible, or the live path failed — the backfill retries once).
-- {"failed"} = the backfill gave up (reason + timestamp), so a broken source leaves the work queue.
--
-- SEALED (ciphertext) assets are never touched: the generator refuses purpose 'sealed_media' outright,
-- and the queue index below excludes them. The download endpoint resolves ?variant= through
-- variants->'<name>'->>'key' and falls back to object_key when absent.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS, CREATE INDEX IF NOT EXISTS.
BEGIN;

ALTER TABLE media_assets ADD COLUMN IF NOT EXISTS variants jsonb;

-- The backfill's work queue: ready plain images with nothing generated yet, oldest first. Partial,
-- so it costs nothing on the rows that are done.
CREATE INDEX IF NOT EXISTS idx_media_assets_variants_pending
  ON media_assets (created_at, id)
  WHERE status = 'ready' AND variants IS NULL AND mime_type LIKE 'image/%' AND purpose <> 'sealed_media';

COMMIT;
