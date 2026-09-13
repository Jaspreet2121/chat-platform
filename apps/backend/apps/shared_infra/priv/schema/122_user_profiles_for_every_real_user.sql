-- 122: every REAL user has a user_profiles row.
--
-- Only PATCH /users/me ever created user_profiles; registration wrote users_auth alone. An account
-- that signed up and never saved a name could message freely, yet every peer's card fetch for it
-- was a 404 (user 91d232ce…: active since 31 Jul, in a DM and a group, no card, 404 ×10 in 48h).
-- From here registration inserts the profile row in the same transaction as the account
-- (AuthService.Accounts.register_user/1); this backfills the accounts that predate it.
--
-- REAL users only: status = 'active' AND at least one device_sessions row — a session exists only
-- for an account that completed an OTP verify. Prod (13 Sep): 5 rows expected. The 1642 active
-- rows with no session ever (the shadow set, handled separately in 123) are NOT touched: they get
-- no card, exactly as before.
--
-- display_name may now be NULL: the registration row carries no name until the user sets one, and
-- the read path answers a minimal card (has_profile: false) rather than fabricating one.
--
-- Idempotent: the ALTER is a no-op when already nullable; the INSERT is guarded by NOT EXISTS and
-- ON CONFLICT DO NOTHING, and logs how many rows it added (0 on a re-run).
BEGIN;

ALTER TABLE user_profiles ALTER COLUMN display_name DROP NOT NULL;

DO $$
DECLARE
  n integer;
BEGIN
  INSERT INTO user_profiles (user_id, app_id, display_name)
  SELECT ua.id, ua.app_id, NULL
  FROM users_auth ua
  WHERE ua.status = 'active'
    AND NOT EXISTS (SELECT 1 FROM user_profiles up WHERE up.user_id = ua.id)
    AND EXISTS (SELECT 1 FROM device_sessions ds WHERE ds.user_id = ua.id)
  ON CONFLICT (user_id) DO NOTHING;

  GET DIAGNOSTICS n = ROW_COUNT;
  RAISE NOTICE '122: backfilled % user_profiles row(s) for real users without a card', n;
END $$;

COMMIT;
