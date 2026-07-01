-- 053: Composite (app_id, id) index on conversations — supports the public /v1 tenant-isolation gate's
-- lookup, which resolves a conversation ONLY within the caller's app_id (WHERE app_id = $1 AND id = $2).
-- The plain (app_id) index from 048 and the id primary key each cover one column; this composite lets
-- the tenant-scoped point lookup be served by a single index as the conversation set grows per app.
--
-- Idempotent + transactional, so it applies to BOTH a fresh initdb volume AND an already-running DB:
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -v ON_ERROR_STOP=1 \
--     < infra/docker/postgres/init/053_conversation_tenant_index.sql

BEGIN;

CREATE INDEX IF NOT EXISTS idx_conversations_app_id_id ON conversations (app_id, id);

COMMIT;
