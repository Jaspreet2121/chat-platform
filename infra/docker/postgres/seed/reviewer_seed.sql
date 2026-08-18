-- Play-reviewer seed (2026-08-18) — run ONCE against prod, DELIBERATELY OUTSIDE the numbered
-- migration stream (init/*.sql): this is environment DATA, not schema, and the test-postgres gate
-- rebuilds test databases from init/* — reviewer rows do not belong in every test DB.
--
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < infra/docker/postgres/seed/reviewer_seed.sql
--
-- Two tenant-zero accounts (invisible to every other tenant by app_id scoping):
--   Play Reviewer  +15550100001  @playreviewer   — the account Google signs in with
--   Skifi Support  +15550100002  @skifisupport   — the peer that makes Chats/Calls non-empty
-- plus their 1:1 conversation and one answered call-history row. The welcome MESSAGE cannot be
-- seeded by SQL (messages live in ScyllaDB) — it is sent once through the real API; see
-- docs/09-devops/REVIEWER_LOGIN.md step 3.
--
-- IDEMPOTENT: fixed uuids + ON CONFLICT DO NOTHING throughout; re-running changes nothing.
-- The phone numbers MUST match the REVIEWER_TEST_LOGINS env (the OTP path finds users by phone;
-- a different env phone would auto-create a fresh, empty account instead of landing here).
BEGIN;

INSERT INTO users_auth (id, app_id, phone_number, password_hash, status, created_at, updated_at)
VALUES
  ('aaaaaaaa-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000001',
   '+15550100001', 'x', 'active', now(), now()),
  ('aaaaaaaa-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000001',
   '+15550100002', 'x', 'active', now(), now())
ON CONFLICT (id) DO NOTHING;

INSERT INTO user_profiles (user_id, display_name, username, username_key, app_id, created_at, updated_at)
VALUES
  ('aaaaaaaa-0000-4000-8000-000000000001', 'Play Reviewer', 'playreviewer', 'playreviewer',
   '00000000-0000-0000-0000-000000000001', now(), now()),
  ('aaaaaaaa-0000-4000-8000-000000000002', 'Skifi Support', 'skifisupport', 'skifisupport',
   '00000000-0000-0000-0000-000000000001', now(), now())
ON CONFLICT (user_id) DO NOTHING;

INSERT INTO conversations (id, app_id, type, created_by, status, created_at, updated_at)
VALUES
  ('aaaaaaaa-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000001', 'direct',
   'aaaaaaaa-0000-4000-8000-000000000002', 'active', now(), now())
ON CONFLICT (id) DO NOTHING;

INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at)
VALUES
  ('aaaaaaaa-0000-4000-8000-000000000003', 'aaaaaaaa-0000-4000-8000-000000000001', 'member', now()),
  ('aaaaaaaa-0000-4000-8000-000000000003', 'aaaaaaaa-0000-4000-8000-000000000002', 'member', now())
ON CONFLICT (conversation_id, user_id) DO NOTHING;

-- One answered voice call (support → reviewer, 42s) so the Calls tab isn't empty. app_id stamped
-- (097); status vocabulary per 066/097.
INSERT INTO calls (id, room_name, kind, app_id, caller_id, callee_id, conversation_id, type, status,
                   created_at, answered_at, ended_at)
VALUES
  ('aaaaaaaa-0000-4000-8000-000000000004', 'call-seed-reviewer-1', 'direct',
   '00000000-0000-0000-0000-000000000001',
   'aaaaaaaa-0000-4000-8000-000000000002', 'aaaaaaaa-0000-4000-8000-000000000001',
   'aaaaaaaa-0000-4000-8000-000000000003', 'voice', 'ended',
   now() - interval '1 day', now() - interval '1 day' + interval '5 seconds',
   now() - interval '1 day' + interval '47 seconds')
ON CONFLICT (id) DO NOTHING;

COMMIT;
