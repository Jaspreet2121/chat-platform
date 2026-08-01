-- USER EMAIL: make per-tenant email uniqueness CASE-INSENSITIVE.
--
-- WHAT WAS ALREADY DONE (verified before writing this — no migration needed for it): 048 ALREADY
-- re-scoped email to per-tenant, in the same block as phone:
--     users_auth_email_key → UNIQUE (app_id, email) WHERE email IS NOT NULL
-- Email was NOT left behind. Two tenants can already hold the same address.
--
-- WHAT IS STILL WRONG, and is what this migration fixes: that index is on the RAW value, so
-- 'Bob@x.com' and 'bob@x.com' are two DIFFERENT rows in ONE tenant — the same address, twice. Email
-- domains are case-insensitive and every mail provider treats local parts that way in practice, so
-- the uniqueness that matters is on the folded value. This mirrors the usernames slice, which folds
-- to `username_key` for exactly this reason.
--
-- Writes normalise to lowercase (AuthService.Accounts.update_email), so first-party data is already
-- canonical; this index is what stops a second writer — or pre-existing mixed-case data — from
-- reintroducing the duplicate.
--
-- IF THIS MIGRATION FAILS on an existing database, it is telling you something real: two rows in one
-- tenant already differ only by case. Resolve those rows first (they are duplicate accounts for one
-- address); do not weaken the index.
--
-- Idempotent + transactional:
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../091_email_case_insensitive_unique.sql
BEGIN;

DROP INDEX IF EXISTS users_auth_email_key;
CREATE UNIQUE INDEX IF NOT EXISTS users_auth_email_key
  ON users_auth (app_id, lower(email)) WHERE email IS NOT NULL;

COMMIT;
