-- 055: App ownership — self-serve integrator onboarding. A first-party user can register a business
-- "app" and becomes its owner; app-scoped actions (issuing keys, later webhooks) are authorized against
-- this table. Turns "everything on tenant-zero" into real multi-tenant: each integrator on its OWN live
-- app_id.
--
-- Model: MANY apps per user, and an app has at least one owner. Ownership is recorded ONLY for live apps
-- a user explicitly creates — NOT for test twins (a twin is derived and belongs to its parent live app,
-- so it never gets an app_owners row). owner_user_id → users_auth(id) (the first-party account that
-- registered the business). tenant-zero (the DEFAULT app) has no owner row and stays the shared default.
--
-- Idempotent + transactional, so it applies to BOTH a fresh initdb volume AND an already-running DB:
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -v ON_ERROR_STOP=1 \
--     < infra/docker/postgres/init/055_app_owners.sql

BEGIN;

CREATE TABLE IF NOT EXISTS app_owners (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id uuid NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  owner_user_id uuid NOT NULL REFERENCES users_auth(id) ON DELETE CASCADE,
  role text NOT NULL DEFAULT 'owner',
  created_at timestamptz NOT NULL DEFAULT now()
);

-- One ownership row per (app, user); the authz lookup is (app_id, owner_user_id).
CREATE UNIQUE INDEX IF NOT EXISTS app_owners_app_owner_unique ON app_owners (app_id, owner_user_id);
-- List-my-apps lookup by owner.
CREATE INDEX IF NOT EXISTS idx_app_owners_owner ON app_owners (owner_user_id);

COMMIT;
