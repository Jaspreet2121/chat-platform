-- 121: ONE fcm_tokens row per device.
--
-- The upsert was keyed on `token` (074), so a rotated registration token inserted a SECOND row for
-- the same handset and nothing ever removed the first. Prod (13 Sep 2026): 50 rows, 1 colliding
-- (user_id, device_id) group holding 1 extra row, 0 NULL device_ids — small today, unbounded by
-- construction. From here the key is the DEVICE: (user_id, device_id) is unique and NOT NULL, and
-- AuthService.FcmTokens.upsert_token/1 targets it.
--
-- Every step is a no-op on re-run: the DELETEs find nothing, SET NOT NULL on a NOT NULL column is
-- accepted silently, and the index is IF NOT EXISTS. Applied in ONE transaction so a half-migrated
-- table (deduped but not yet keyed) cannot be observed.
BEGIN;

-- 1. A row with no device can never be addressed by a device-keyed upsert and cannot survive
--    NOT NULL. Prod holds none; this is the guard, not a cleanup.
DELETE FROM fcm_tokens WHERE device_id IS NULL;

-- 2. Dedup: keep the NEWEST row per (user_id, device_id) — updated_at, then id as a deterministic
--    tiebreak so two rows written in the same instant cannot both survive.
DELETE FROM fcm_tokens stale
USING fcm_tokens newer
WHERE newer.user_id = stale.user_id
  AND newer.device_id = stale.device_id
  AND (newer.updated_at > stale.updated_at
       OR (newer.updated_at = stale.updated_at AND newer.id > stale.id));

-- 3. The column the key stands on.
ALTER TABLE fcm_tokens ALTER COLUMN device_id SET NOT NULL;

-- 4. The device key. A unique INDEX (not a constraint) is a valid ON CONFLICT arbiter and is the
--    only form that can be created IF NOT EXISTS.
CREATE UNIQUE INDEX IF NOT EXISTS fcm_tokens_user_device_key ON fcm_tokens (user_id, device_id);

COMMIT;
