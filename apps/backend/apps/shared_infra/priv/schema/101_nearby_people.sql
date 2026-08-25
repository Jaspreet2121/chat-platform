-- Nearby People (101): short-lived, explicit proximity discovery plus consent-based connections.
-- Coordinates are server-only and expire after five minutes. Public responses expose only a coarse
-- distance bucket (100/200 m, pinned per viewer for the row's lifetime), never latitude, longitude,
-- accuracy, or an exact distance. Expired rows are physically deleted by the next discover/stop.
BEGIN;

CREATE TABLE IF NOT EXISTS nearby_presence (
  user_id uuid PRIMARY KEY REFERENCES users_auth(id) ON DELETE CASCADE,
  app_id uuid NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  latitude double precision NOT NULL CHECK (latitude BETWEEN -90 AND 90),
  longitude double precision NOT NULL CHECK (longitude BETWEEN -180 AND 180),
  accuracy_m real NOT NULL CHECK (accuracy_m >= 0 AND accuracy_m <= 100),
  expires_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  -- Per-viewer pinned distance buckets ({viewer_uuid: 100|200}) — the anti-trilateration pin: the
  -- FIRST bucket computed for a (viewer, target) pair is returned for the whole lifetime of this
  -- presence row, so a moving attacker cannot walk the bucket boundary. Lives on the row so
  -- deletion/re-creation clears it for free (no second table, no sweep).
  pins jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS nearby_presence_active_idx
  ON nearby_presence (app_id, expires_at DESC);

CREATE TABLE IF NOT EXISTS nearby_connection_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id uuid NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  requester_user_id uuid NOT NULL REFERENCES users_auth(id) ON DELETE CASCADE,
  recipient_user_id uuid NOT NULL REFERENCES users_auth(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'accepted', 'declined', 'cancelled')),
  created_at timestamptz NOT NULL DEFAULT now(),
  responded_at timestamptz,
  CONSTRAINT nearby_request_no_self CHECK (requester_user_id <> recipient_user_id)
);

-- One pending request per unordered pair. A reverse request cannot bypass the recipient's explicit
-- accept/decline choice.
CREATE UNIQUE INDEX IF NOT EXISTS nearby_requests_pending_pair_idx
  ON nearby_connection_requests (
    app_id,
    LEAST(requester_user_id, recipient_user_id),
    GREATEST(requester_user_id, recipient_user_id)
  ) WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS nearby_requests_recipient_idx
  ON nearby_connection_requests (recipient_user_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS nearby_requests_requester_idx
  ON nearby_connection_requests (requester_user_id, status, created_at DESC);

CREATE TABLE IF NOT EXISTS nearby_connections (
  app_id uuid NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  user_low_id uuid NOT NULL REFERENCES users_auth(id) ON DELETE CASCADE,
  user_high_id uuid NOT NULL REFERENCES users_auth(id) ON DELETE CASCADE,
  connected_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_low_id, user_high_id),
  CONSTRAINT nearby_connection_canonical_pair CHECK (user_low_id < user_high_id)
);

CREATE INDEX IF NOT EXISTS nearby_connections_high_idx
  ON nearby_connections (user_high_id, connected_at DESC);

COMMIT;
