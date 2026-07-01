-- 052: Webhook failed-delivery ops (Phase 4). An append-only audit log of manual recovery actions +
-- a partial index that keeps the failed-list query fast as the outbox grows.
--
-- Adapted to THIS repo's webhook_outbox schema (051): timestamp column is `created_at` (not
-- inserted_at); there is no locked_until/updated_at; the URL lives on webhook_endpoints (joined at
-- read time). The audit log is append-only (never updated/deleted) and intentionally has no FK to
-- webhook_outbox so it survives even if an outbox row is later pruned.
--
-- Idempotent + transactional (fresh initdb volume AND a running DB):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -v ON_ERROR_STOP=1 \
--     < infra/docker/postgres/init/052_webhook_outbox_ops.sql

BEGIN;

-- Failed-list queries touch only failed rows → partial index keeps it small/fast (keyset order).
CREATE INDEX IF NOT EXISTS webhook_outbox_failed_idx
  ON webhook_outbox (app_id, created_at, id) WHERE status = 'failed';

CREATE TABLE IF NOT EXISTS webhook_outbox_audit (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outbox_id uuid NOT NULL,
  event_id uuid NOT NULL,
  action text NOT NULL,          -- 'reenqueue' | 'reenqueue_bulk'
  actor text,                    -- admin user_id (from the verified admin session)
  from_status text,
  to_status text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_webhook_outbox_audit_event ON webhook_outbox_audit (event_id);
CREATE INDEX IF NOT EXISTS idx_webhook_outbox_audit_outbox ON webhook_outbox_audit (outbox_id);

COMMIT;
