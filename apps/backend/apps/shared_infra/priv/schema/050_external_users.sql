-- 050: External (integrator) end-users. A token-exchange call maps an integrator's opaque end-user id
-- to a stable user row WITHIN that app_id — so App-A's "alice" and App-B's "alice" are DIFFERENT rows
-- (the multi-tenancy payoff). These users have no phone/email, only an external_id, so the original
-- "phone OR email NOT NULL" identity check must be relaxed to also accept external_id.
--
-- Idempotent + transactional (applies to a fresh initdb volume AND a running DB):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -v ON_ERROR_STOP=1 \
--     < infra/docker/postgres/init/050_external_users.sql

BEGIN;

ALTER TABLE users_auth ADD COLUMN IF NOT EXISTS external_id text;

-- Drop the original identity CHECK (phone_number OR email) by FINDING it (robust to its auto-name),
-- then add the relaxed one that also accepts external_id. Both steps are idempotent.
DO $$
DECLARE
  old_check text;
BEGIN
  SELECT conname INTO old_check
  FROM pg_constraint
  WHERE conrelid = 'users_auth'::regclass
    AND contype = 'c'
    AND pg_get_constraintdef(oid) LIKE '%phone_number%'
    AND pg_get_constraintdef(oid) LIKE '%email%'
    AND pg_get_constraintdef(oid) NOT LIKE '%external_id%'
    AND pg_get_constraintdef(oid) NOT LIKE '%status%'
  LIMIT 1;

  IF old_check IS NOT NULL THEN
    EXECUTE format('ALTER TABLE users_auth DROP CONSTRAINT %I', old_check);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'users_auth_identity_check') THEN
    ALTER TABLE users_auth
      ADD CONSTRAINT users_auth_identity_check
      CHECK (phone_number IS NOT NULL OR email IS NOT NULL OR external_id IS NOT NULL);
  END IF;
END $$;

-- One row per (app_id, external_id): the resolve-or-create lookup key, scoped per app.
CREATE UNIQUE INDEX IF NOT EXISTS users_auth_app_external_id_key
  ON users_auth (app_id, external_id) WHERE external_id IS NOT NULL;

COMMIT;
