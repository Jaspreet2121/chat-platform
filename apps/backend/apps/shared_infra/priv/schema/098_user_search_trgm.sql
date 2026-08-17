-- Feature: user search by display name / username (GET /api/v1/users/search, 2026-08-17).
--
-- pg_trgm GIN expression indexes so a case-insensitive SUBSTRING match (lower(col) LIKE '%q%') is an
-- index scan instead of a per-app seq scan. pg_trgm ships in the postgres:16-alpine image's contrib
-- set, so CREATE EXTENSION is available on the prod container (and the test-postgres gate applying
-- this file against the same image is the standing proof).
--
-- NOT composite with app_id: a (app_id, lower(...)) GIN would need the btree_gin extension for the
-- uuid column — not worth it. app_id (+ users_auth.status) stay residual filters on the trigram
-- candidates, which is cheap at this table's scale.
--
-- Idempotent + transactional (fresh initdb volume AND an already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../098_user_search_trgm.sql
BEGIN;

CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE INDEX IF NOT EXISTS idx_user_profiles_display_name_trgm
  ON user_profiles USING gin (lower(display_name) gin_trgm_ops);

-- username is nullable; NULLs simply don't index.
CREATE INDEX IF NOT EXISTS idx_user_profiles_username_trgm
  ON user_profiles USING gin (lower(username) gin_trgm_ops);

COMMIT;
