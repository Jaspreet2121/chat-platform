-- 109: Secret chats v2 — per-app default-on (opportunistic E2EE). apps.e2ee_default gates the
-- auto-upgrade of NEW 1:1 conversations (server-side at create) and signals capable clients to
-- upgrade EXISTING 1:1s. New integrator apps stay false; a dashboard toggle is a recorded
-- follow-up.
--
-- BACKFILL to TRUE: tenant-zero (the first-party ExWay/Skifi app, exact id) plus the Skifi live
-- app and its test twin — matched by ID PREFIX (274c8a2c… / 869819fa…, the ids recorded in
-- DECISION_LOG), so the statement uses whatever full uuid production actually holds and is a clean
-- no-op on a fresh/test DB that lacks them. Idempotent + guarded.
--
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../109_e2ee_default.sql
BEGIN;

ALTER TABLE apps ADD COLUMN IF NOT EXISTS e2ee_default boolean NOT NULL DEFAULT false;

UPDATE apps SET e2ee_default = true
WHERE id = '00000000-0000-0000-0000-000000000001'
   OR id::text LIKE '274c8a2c%'
   OR id::text LIKE '869819fa%';

COMMIT;
