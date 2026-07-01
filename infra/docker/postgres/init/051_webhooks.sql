-- 051: Webhooks — durable event delivery to integrator endpoints. Two tables:
--   webhook_endpoints  — a registered URL per app, with a RECOVERABLE signing secret (the worker signs
--                        each delivery with it; it is NOT hashed — the integrator verifies with the same
--                        secret). No app-level encryption key exists, so it is stored plaintext and
--                        returned to the integrator ONCE at creation (list/get never re-expose it). A
--                        KMS/Cloak-encrypted column is the documented prod hardening.
--   webhook_outbox     — the durable delivery queue (transactional/after-commit emit, persistent retry,
--                        dead-letter). One row PER (event, endpoint) so each endpoint has its own retry +
--                        signing + dead-letter state. event_id is stable across retries for dedupe.
--
-- The worker claims due rows with FOR UPDATE SKIP LOCKED (multi-replica safe). Indexes: (status,
-- next_attempt_at) for the poll, plus app_id / endpoint_id.
--
-- Idempotent + transactional (fresh initdb volume AND a running DB):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -v ON_ERROR_STOP=1 \
--     < infra/docker/postgres/init/051_webhooks.sql

BEGIN;

CREATE TABLE IF NOT EXISTS webhook_endpoints (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id uuid NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  url text NOT NULL,
  -- Recoverable signing secret (plaintext; used by the worker to HMAC-sign deliveries). Returned once.
  signing_secret text NOT NULL,
  enabled boolean NOT NULL DEFAULT true,
  -- Which event types this endpoint subscribes to (e.g. {message.created,conversation.created}).
  event_types text[] NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_webhook_endpoints_app_id ON webhook_endpoints (app_id);

CREATE TABLE IF NOT EXISTS webhook_outbox (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id uuid NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  endpoint_id uuid NOT NULL REFERENCES webhook_endpoints(id) ON DELETE CASCADE,
  -- Stable event id surfaced in the delivery so an integrator can dedupe; unchanged across retries.
  event_id uuid NOT NULL,
  event_type text NOT NULL,
  payload jsonb NOT NULL,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'delivering', 'delivered', 'failed')),
  attempts int NOT NULL DEFAULT 0,
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  last_error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  delivered_at timestamptz
);

-- The worker poll: due rows = status='pending' AND next_attempt_at <= now(), claimed SKIP LOCKED.
CREATE INDEX IF NOT EXISTS idx_webhook_outbox_due ON webhook_outbox (status, next_attempt_at);
CREATE INDEX IF NOT EXISTS idx_webhook_outbox_app_id ON webhook_outbox (app_id);
CREATE INDEX IF NOT EXISTS idx_webhook_outbox_endpoint ON webhook_outbox (endpoint_id);

COMMIT;
