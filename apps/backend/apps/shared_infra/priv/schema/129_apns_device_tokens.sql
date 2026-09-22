-- Feature 129: APPLE PUSH device tokens — one table for every platform's push credential.
--
-- `fcm_tokens` (074) was built when Android was the only handset: `platform` defaults to 'android'
-- and the gateway route hard-codes that value, so the table already holds the shape iOS needs. It
-- keeps its name rather than gaining a migration to rename it: the name is wrong but it is written
-- into notification-service's fan-out SQL, the auth service's store and three test suites, and a
-- rename buys nothing an honest comment cannot.
--
--   kind        — WHICH push channel this token is for. Android has one; Apple has TWO, and they are
--                 different credentials for different topics: an `alert` token addresses
--                 com.growblic.exway and carries message notifications, a `voip` token addresses
--                 com.growblic.exway.voip and is the ONLY thing that may carry an incoming call,
--                 because CallKit requires apns-push-type: voip. Sending an alert payload to a VoIP
--                 token, or the reverse, is rejected by APNs — so the channel has to be stored, not
--                 inferred.
--   environment — sandbox or production. The SAME device token is valid at exactly one of the two
--                 APNs hosts, and which one depends on how the app was signed, not on how the server
--                 was deployed: a TestFlight build and an App Store build of the same binary differ
--                 here. A server-wide setting would break one of them, so the client tells us and we
--                 store it per token.
--
-- Both are NULLABLE with a NULL meaning "not applicable", which is what every existing Android row
-- is. No backfill: `platform='android'` rows keep NULL on both and the FCM leg never reads them.
--
-- Idempotent + transactional (fresh initdb volume AND an already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -v ON_ERROR_STOP=1 \
--     < infra/docker/postgres/init/129_apns_device_tokens.sql
BEGIN;

ALTER TABLE fcm_tokens ADD COLUMN IF NOT EXISTS kind text;
ALTER TABLE fcm_tokens ADD COLUMN IF NOT EXISTS environment text;

-- Constrained rather than free text: these two values choose an APNs HOST and an apns-push-type
-- HEADER. A typo would not fail loudly, it would silently send every call push to the wrong topic.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fcm_tokens_kind_check') THEN
    ALTER TABLE fcm_tokens ADD CONSTRAINT fcm_tokens_kind_check
      CHECK (kind IS NULL OR kind IN ('alert', 'voip'));
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fcm_tokens_environment_check') THEN
    ALTER TABLE fcm_tokens ADD CONSTRAINT fcm_tokens_environment_check
      CHECK (environment IS NULL OR environment IN ('sandbox', 'production'));
  END IF;

  -- `platform` had no constraint at all — the column that decides WHICH SENDER handles a row was
  -- free text with an application-level allowlist in front of it. Now that a second platform exists,
  -- a bad value means a token nobody ever sends to, silently.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fcm_tokens_platform_check') THEN
    ALTER TABLE fcm_tokens ADD CONSTRAINT fcm_tokens_platform_check
      CHECK (platform IN ('android', 'ios', 'web'));
  END IF;
END $$;

-- ONE ROW PER DEVICE IS NOW WRONG, and this is the part that breaks silently if it is missed.
--
-- `fcm_tokens_user_device_key` is UNIQUE (user_id, device_id) — one push credential per handset,
-- which was true while Android was the only handset. An iPhone registers TWO: an alert token and a
-- VoIP token, different credentials for different topics on the same device. Under the old index the
-- second registration would UPDATE the first, and the account would end up with whichever one the
-- app happened to register last — messages arriving and calls not ringing, or the reverse.
--
-- COALESCE, not a bare three-column index: NULLs are DISTINCT in a unique btree, so
-- (user_id, device_id, kind) with kind NULL would make every Android re-registration a NEW row
-- instead of an upsert, and the fan-out would send one push per historical registration. Every
-- existing row has kind NULL and must keep collapsing to exactly one key.
DROP INDEX IF EXISTS fcm_tokens_user_device_key;
ALTER TABLE fcm_tokens DROP CONSTRAINT IF EXISTS fcm_tokens_user_device_key;

CREATE UNIQUE INDEX IF NOT EXISTS fcm_tokens_user_device_kind_key
  ON fcm_tokens (user_id, device_id, COALESCE(kind, ''));

-- The APNs fan-out reads "every ios token for this recipient, by kind": an alert push wants the
-- alert tokens, an incoming call wants the voip ones. Partial, because iOS rows are a minority of
-- this table for as long as Android is the larger install base.
CREATE INDEX IF NOT EXISTS fcm_tokens_apns_idx
  ON fcm_tokens (user_id, kind) WHERE platform = 'ios';

COMMIT;
