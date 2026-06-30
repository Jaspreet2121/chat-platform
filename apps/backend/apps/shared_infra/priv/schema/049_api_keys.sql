-- 049: Secret API keys per app (tenant) — the credential an integrator's SERVER uses to call /v1.
--
-- SECURITY: the full secret key (sk_live_…) is NEVER stored. We store only sha256(key) in key_hash
-- (unique) plus a short non-secret key_prefix for display/lookup. The raw key is returned to the
-- caller exactly ONCE at creation and is unrecoverable afterward. Auth = sha256(presented) → match
-- key_hash (an indexed exact lookup, so no prefix-vs-full timing distinction).
--
-- Idempotent + transactional, so it applies to BOTH a fresh initdb volume AND an already-running DB:
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -v ON_ERROR_STOP=1 \
--     < infra/docker/postgres/init/049_api_keys.sql

BEGIN;

CREATE TABLE IF NOT EXISTS api_keys (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id uuid NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  name text NOT NULL,
  -- sha256(full key), hex. UNIQUE so a presented key resolves to at most one row.
  key_hash text NOT NULL UNIQUE,
  -- Non-secret leading slice (e.g. "sk_live_AbCd1234") for display + operator lookup. NOT the secret.
  key_prefix text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_used_at timestamptz,
  revoked_at timestamptz
);

CREATE INDEX IF NOT EXISTS idx_api_keys_app_id ON api_keys (app_id);
CREATE INDEX IF NOT EXISTS idx_api_keys_key_prefix ON api_keys (key_prefix);

COMMIT;
