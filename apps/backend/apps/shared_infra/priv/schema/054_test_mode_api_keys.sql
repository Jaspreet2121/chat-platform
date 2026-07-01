-- 054: Test-mode API keys (sk_test_) with app_id-scoped test↔live isolation.
--
-- DESIGN: test mode is separated by app_id, NOT by a per-row mode predicate. A test key resolves to a
-- DISTINCT app_id (the integrator's "test twin" app) from its live key. The existing app_id tenant seal
-- (V1Auth / realtime / webhook registration all key on app_id) then isolates test from live FOR FREE —
-- no new predicate on conversations/messages, and test data can't leak into live because it's the same
-- tenant seal already proven by the cross-tenant acceptance tests.
--
--   * api_keys.mode  — 'live' | 'test' (which key class; sk_live_ / sk_test_). Default 'live' so every
--                      existing key is unchanged.
--   * apps.parent_app_id + apps.mode — a test app is a "twin" of a live app: parent_app_id → the live
--                      app, mode='test'. Exactly one test twin per live app (partial unique index).
--
-- Idempotent + transactional, so it applies to BOTH a fresh initdb volume AND an already-running DB:
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -v ON_ERROR_STOP=1 \
--     < infra/docker/postgres/init/054_test_mode_api_keys.sql

BEGIN;

ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS mode text NOT NULL DEFAULT 'live';

ALTER TABLE apps ADD COLUMN IF NOT EXISTS parent_app_id uuid;
ALTER TABLE apps ADD COLUMN IF NOT EXISTS mode text NOT NULL DEFAULT 'live';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'api_keys_mode_check') THEN
    ALTER TABLE api_keys ADD CONSTRAINT api_keys_mode_check CHECK (mode IN ('live', 'test'));
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'apps_mode_check') THEN
    ALTER TABLE apps ADD CONSTRAINT apps_mode_check CHECK (mode IN ('live', 'test'));
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'apps_parent_app_id_fkey') THEN
    ALTER TABLE apps ADD CONSTRAINT apps_parent_app_id_fkey
      FOREIGN KEY (parent_app_id) REFERENCES apps(id);
  END IF;
END $$;

-- One test twin per live app: the find-or-create at key-issue time relies on this to converge under
-- concurrent issuance (second inserter hits the unique violation → re-selects the winner).
CREATE UNIQUE INDEX IF NOT EXISTS apps_test_twin_unique ON apps (parent_app_id) WHERE mode = 'test';

COMMIT;
