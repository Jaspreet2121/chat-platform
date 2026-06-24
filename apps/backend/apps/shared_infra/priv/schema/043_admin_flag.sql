-- Phase 0 admin foundation: a global platform-admin flag on the core identity.
--
-- Idempotent (ADD COLUMN IF NOT EXISTS) so it applies cleanly to BOTH a fresh initdb volume (auto-run)
-- AND an already-running database (run it manually to avoid recreating the volume / losing local data):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -c \
--     "ALTER TABLE users_auth ADD COLUMN IF NOT EXISTS is_admin boolean NOT NULL DEFAULT false;"
ALTER TABLE users_auth ADD COLUMN IF NOT EXISTS is_admin boolean NOT NULL DEFAULT false;
