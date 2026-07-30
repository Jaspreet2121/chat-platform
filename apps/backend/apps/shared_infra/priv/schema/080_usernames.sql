-- Feature: USERNAMES — a stable, optional @handle for discovery without exposing a phone number.
--
--   user_profiles.username      — the handle AS TYPED (case-preserving display). Nullable: optional.
--   user_profiles.username_key  — lower(username), the NORMALISED key. The accepted alphabet is pure
--                                 ASCII (^[A-Za-z][A-Za-z0-9_]{2,29}$), so lowercase IS the whole
--                                 normalisation (NFKC is deliberately a no-op — anything that would
--                                 need it is rejected). Uniqueness + lookup use ONLY this key.
--
-- Uniqueness is PER-TENANT — (app_id, username_key) — matching phone (048) and external_id (050):
-- tenants are separate consumer products; a global namespace would let one tenant's squatter block
-- every other tenant's users and leak existence across products. There is NO app-blind lookup path.
--
--   username_holds — a vacated handle is NOT released for 30 days (rename, removal, and account
--   deletion all write a hold), closing the claim-a-name-someone-just-vacated impersonation vector.
--   The vacating owner may reclaim inside the window (hold.user_id = them). These rows are never
--   deleted by user action, and double as the CHANGE BUDGET: a user's holds created in the last 30
--   days count their changes (2 max) — so @a → @b → @a cannot refund itself (reclaim writes hold(@b)
--   and hold(@a) stays). PK (app_id, username_key): re-vacating the same handle renews the row.
--
-- Idempotent + transactional (fresh initdb volume AND an already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../080_usernames.sql
BEGIN;

ALTER TABLE user_profiles ADD COLUMN IF NOT EXISTS username text;
ALTER TABLE user_profiles ADD COLUMN IF NOT EXISTS username_key text;

CREATE UNIQUE INDEX IF NOT EXISTS user_profiles_app_username_key
  ON user_profiles (app_id, username_key) WHERE username_key IS NOT NULL;

CREATE TABLE IF NOT EXISTS username_holds (
  app_id uuid NOT NULL REFERENCES apps(id),
  username_key text NOT NULL,
  user_id uuid NOT NULL,
  held_until timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (app_id, username_key)
);

-- The change-budget count: MY holds created in the rolling window.
CREATE INDEX IF NOT EXISTS idx_username_holds_user ON username_holds (user_id, created_at DESC);

COMMIT;
