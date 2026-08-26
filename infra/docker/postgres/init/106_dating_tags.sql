-- 106: Dating v2 — intention + turn-ons (Pure-style common ground). 105 stored prefs as PLAIN
-- COLUMNS (min_age/max_age/max_distance_km/pref_genders), so v2 extends the same shape: two
-- profile facts (intention, ordered turn_ons) and two prefs (pref_intentions filter,
-- pref_require_shared_turn_on). The tag CATALOG itself is a code module (SharedInfra.DatingTags,
-- the builtin_commands precedent) — keys are the wire contract, no DB table.
--
-- BACKFILL: rows enabled under the 105 gate never provided an intention — stamp 'figuring' so the
-- enable gate doesn't retroactively break them. A DISABLED row stays NULL: any future enable must
-- state an intention explicitly.
--
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../106_dating_tags.sql
BEGIN;

ALTER TABLE dating_profiles ADD COLUMN IF NOT EXISTS intention text
  CHECK (intention IN ('serious', 'casual', 'open', 'friends', 'figuring'));
ALTER TABLE dating_profiles ADD COLUMN IF NOT EXISTS turn_ons text[] NOT NULL DEFAULT '{}';
ALTER TABLE dating_profiles ADD COLUMN IF NOT EXISTS pref_intentions text[] NOT NULL DEFAULT '{}';
ALTER TABLE dating_profiles
  ADD COLUMN IF NOT EXISTS pref_require_shared_turn_on boolean NOT NULL DEFAULT false;

UPDATE dating_profiles SET intention = 'figuring' WHERE enabled AND intention IS NULL;

COMMIT;
