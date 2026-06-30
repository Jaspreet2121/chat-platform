-- 048: Multi-tenant foundation — every core row belongs to an "app" (tenant). The existing single
-- app becomes "tenant zero" (a fixed default app) with ZERO behavior change.
--
-- What this does:
--   1) Create `apps` and seed the DEFAULT app (fixed UUID 00000000-0000-0000-0000-000000000001).
--   2) Add app_id to every core table — nullable add → backfill existing rows to the default →
--      NOT NULL, and keep a DB DEFAULT of the default app so the CURRENT (unchanged) services' inserts
--      keep working without specifying app_id (no orphans possible). FK each app_id → apps(id).
--   3) Re-scope the three global unique constraints to be PER-APP, keeping the SAME constraint/index
--      NAMES so the Elixir changesets' unique_constraint(...) mappings keep working unchanged:
--        users_auth_phone_number_key  → UNIQUE (app_id, phone_number) WHERE phone_number IS NOT NULL
--        users_auth_email_key         → UNIQUE (app_id, email)        WHERE email IS NOT NULL
--        idx_conversations_direct_key_unique → UNIQUE (app_id, direct_key) WHERE type='direct'
--
-- Idempotent + transactional, so it applies to BOTH a fresh initdb volume AND an already-running DB.
-- To apply to a running stack without recreating the volume:
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -v ON_ERROR_STOP=1 \
--     < infra/docker/postgres/init/048_multi_tenant_app_id.sql

BEGIN;

-- 1) The apps (tenants) table + the default app ("tenant zero").
CREATE TABLE IF NOT EXISTS apps (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  slug text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO apps (id, name, slug)
VALUES ('00000000-0000-0000-0000-000000000001', 'Default App', 'default')
ON CONFLICT (id) DO NOTHING;

-- 2) app_id on every core table: add (nullable) → backfill → DB default → NOT NULL → FK to apps.
DO $$
DECLARE
  t text;
  default_app constant text := '00000000-0000-0000-0000-000000000001';
  core_tables constant text[] := ARRAY[
    'users_auth',
    'user_profiles',
    'conversations',
    'conversation_participants',
    'conversation_settings',
    'group_profiles',
    'messages',
    'message_receipts',
    'message_reactions',
    'starred_messages'
  ];
BEGIN
  FOREACH t IN ARRAY core_tables LOOP
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS app_id uuid', t);
    EXECUTE format('UPDATE %I SET app_id = %L WHERE app_id IS NULL', t, default_app);
    EXECUTE format('ALTER TABLE %I ALTER COLUMN app_id SET DEFAULT %L', t, default_app);
    EXECUTE format('ALTER TABLE %I ALTER COLUMN app_id SET NOT NULL', t);

    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = t || '_app_id_fkey') THEN
      EXECUTE format(
        'ALTER TABLE %I ADD CONSTRAINT %I FOREIGN KEY (app_id) REFERENCES apps(id)',
        t, t || '_app_id_fkey'
      );
    END IF;

    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I (app_id)', 'idx_' || t || '_app_id', t);
  END LOOP;
END $$;

-- 3) Re-scope the global unique constraints to be PER-APP (same names → Ecto mappings unchanged).

-- 3a) Phone + email uniqueness: per (app_id, value). Drop the column-level UNIQUE constraints, then
--     recreate partial unique INDEXES with the SAME names (NULLs stay exempt, matching old semantics).
ALTER TABLE users_auth DROP CONSTRAINT IF EXISTS users_auth_phone_number_key;
ALTER TABLE users_auth DROP CONSTRAINT IF EXISTS users_auth_email_key;
CREATE UNIQUE INDEX IF NOT EXISTS users_auth_phone_number_key
  ON users_auth (app_id, phone_number) WHERE phone_number IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS users_auth_email_key
  ON users_auth (app_id, email) WHERE email IS NOT NULL;

-- 3b) Direct-chat dedup (migration 047): one thread per pair PER APP. Same index name so the
--     conversation changeset's unique_constraint(:direct_key, name: idx_conversations_direct_key_unique)
--     keeps mapping the race-violation error.
DROP INDEX IF EXISTS idx_conversations_direct_key_unique;
CREATE UNIQUE INDEX IF NOT EXISTS idx_conversations_direct_key_unique
  ON conversations (app_id, direct_key) WHERE type = 'direct';

COMMIT;
