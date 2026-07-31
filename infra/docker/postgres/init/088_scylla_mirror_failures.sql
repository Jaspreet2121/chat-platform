-- C7 (dual-write): failed SHADOW writes are RECORDED, not just logged — otherwise the backfill can't
-- know what to repair and the verification report measures a gap it can't explain. One row per failed
-- mirror operation; the repair path (ScyllaBackfill.repair_failures/0, same authority-rebuild shape
-- as C4's repair_media_projections) re-reads the Postgres row and re-mirrors, then stamps
-- resolved_at. Rows are kept after resolution (evidence, same policy as 087's aborted rows).
--
-- Idempotent + transactional:
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../088_scylla_mirror_failures.sql
BEGIN;

CREATE TABLE IF NOT EXISTS scylla_mirror_failures (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid NOT NULL,
  message_id uuid NOT NULL,
  op text NOT NULL,               -- put | edit | delete | receipt | reaction
  reason text NOT NULL,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz
);

-- The repair scan: unresolved failures, oldest first.
CREATE INDEX IF NOT EXISTS scylla_mirror_failures_unresolved_idx
  ON scylla_mirror_failures (inserted_at) WHERE resolved_at IS NULL;

COMMIT;
