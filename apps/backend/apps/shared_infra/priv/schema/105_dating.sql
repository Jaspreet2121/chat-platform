-- 105: Dating — a separate opt-in section (profile + chosen location, swipe deck, visible likes,
-- mutual matches). Deliberately ISOLATED tables: dating data must appear on no other surface, so
-- nothing here touches user_profiles or rides ProfilePresenter. The location is a CHOSEN point
-- (never live GPS — that is Nearby's domain and stays there). Deck geometry is a lat bounding-box
-- prefilter + exact haversine in SQL — fine at this scale; PostGIS is a recorded follow-up, NOT
-- added here.
--
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../105_dating.sql
BEGIN;

CREATE TABLE IF NOT EXISTS dating_profiles (
  user_id uuid PRIMARY KEY REFERENCES users_auth(id) ON DELETE CASCADE,
  app_id uuid NOT NULL REFERENCES apps(id),
  enabled boolean NOT NULL DEFAULT false,
  -- dob is immutable once set, except ONE correction within 48h of dob_set_at (logged via
  -- dob_corrected_at). Age is always computed server-side from dob, never stored.
  dob date,
  dob_set_at timestamptz,
  dob_corrected_at timestamptz,
  gender text CHECK (gender IN ('woman', 'man', 'nonbinary', 'other')),
  interested_in text[] NOT NULL DEFAULT '{}',
  bio text,
  -- Ordered media ids, owner-verified against media_assets at write time. Normal media rows —
  -- dating-only in PRESENTATION, not in storage.
  photos uuid[] NOT NULL DEFAULT '{}',
  latitude double precision,
  longitude double precision,
  location_name text,
  min_age integer NOT NULL DEFAULT 18 CHECK (min_age >= 18),
  max_age integer NOT NULL DEFAULT 100 CHECK (max_age <= 100),
  max_distance_km integer NOT NULL DEFAULT 100 CHECK (max_distance_km BETWEEN 1 AND 500),
  -- Deck-only narrowing on top of interested_in ('{}' = follow interested_in).
  pref_genders text[] NOT NULL DEFAULT '{}',
  last_active_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- The deck scan: enabled candidates of my app inside a latitude band.
CREATE INDEX IF NOT EXISTS dating_profiles_deck_idx
  ON dating_profiles (app_id, enabled, latitude);

CREATE TABLE IF NOT EXISTS dating_swipes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id uuid NOT NULL REFERENCES apps(id),
  swiper_id uuid NOT NULL REFERENCES users_auth(id) ON DELETE CASCADE,
  target_id uuid NOT NULL REFERENCES users_auth(id) ON DELETE CASCADE,
  action text NOT NULL CHECK (action IN ('like', 'pass')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT dating_swipes_no_self CHECK (swiper_id <> target_id)
);

-- One row per direction per pair; action updates in place.
CREATE UNIQUE INDEX IF NOT EXISTS dating_swipes_pair_key
  ON dating_swipes (app_id, swiper_id, target_id);
-- The "likes you" read: who liked me, newest first.
CREATE INDEX IF NOT EXISTS dating_swipes_target_likes_idx
  ON dating_swipes (app_id, target_id, action, updated_at DESC);

CREATE TABLE IF NOT EXISTS dating_matches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id uuid NOT NULL REFERENCES apps(id),
  user_low_id uuid NOT NULL REFERENCES users_auth(id) ON DELETE CASCADE,
  user_high_id uuid NOT NULL REFERENCES users_auth(id) ON DELETE CASCADE,
  -- Nullable: the match commits locally; the 1:1 conversation is created-or-got through the SAME
  -- path every DM uses (the nearby accept precedent) and attached best-effort right after.
  conversation_id uuid,
  matched_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT dating_matches_ordered CHECK (user_low_id < user_high_id)
);

-- One match per unordered pair — the race backstop under concurrent mutual likes.
CREATE UNIQUE INDEX IF NOT EXISTS dating_matches_pair_key
  ON dating_matches (app_id, user_low_id, user_high_id);
CREATE INDEX IF NOT EXISTS dating_matches_low_idx ON dating_matches (user_low_id, matched_at DESC);
CREATE INDEX IF NOT EXISTS dating_matches_high_idx ON dating_matches (user_high_id, matched_at DESC);

COMMIT;
