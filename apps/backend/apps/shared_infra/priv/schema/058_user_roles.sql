-- IAM Phase 1: role-based access control on the core identity.
--
-- Adds a single `role` column to users_auth (ONE role per user; fixed hierarchy
-- root > admin > moderator > support > user). The role→permission mapping lives in CODE
-- (SharedInfra.IAM), so there is no permissions table — roles are permission bundles.
--
-- Idempotent + transactional, so it applies cleanly to BOTH a fresh initdb volume (auto-run) AND an
-- already-running database (run it manually to avoid recreating the volume):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../058_user_roles.sql
--
-- Backfill: existing platform admins (is_admin=true) become role=root so they retain EVERY capability
-- they had; everyone else defaults to 'user' (no admin-console access). The legacy `is_admin` column is
-- KEPT (derived/compat — kept in sync when a role is assigned) so any legacy reader + the current
-- frontend admin gate keep working until Phase 3 migrates them to `role`.
BEGIN;

ALTER TABLE users_auth ADD COLUMN IF NOT EXISTS role text NOT NULL DEFAULT 'user';

-- Backfill existing admins to the highest role (idempotent: only rows still at the default).
UPDATE users_auth SET role = 'root' WHERE is_admin = true AND role = 'user';

-- Defense in depth: constrain the allowed set at the DB layer too (matches SharedInfra.IAM.roles/0).
ALTER TABLE users_auth DROP CONSTRAINT IF EXISTS users_auth_role_check;
ALTER TABLE users_auth
  ADD CONSTRAINT users_auth_role_check
  CHECK (role IN ('root', 'admin', 'moderator', 'support', 'user'));

COMMIT;
