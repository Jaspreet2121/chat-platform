-- Feature: STATUS (Stories) — ephemeral posts visible for 24 hours to a chosen audience, with per-viewer
-- view tracking. ALL FOUR tables ship in this one migration so commits 2 (audience modes + viewer lists)
-- and 3 (replies) are code-only.
--
-- status_posts — one post per row. `expires_at` (created_at + 24h) is enforced by FILTER-AT-READ (every
--   query carries `expires_at > now()`); no scheduler exists and none is assumed. Media BYTES are
--   reclaimed by a WRITE-AMORTISED sweep: each new post drains up to 25 posts expired >1h ago (object
--   purged via the media service, `media_purged_at` stamped), and hard-deletes post+view rows >30 days
--   old — the sweep rate is ≥25× the accrual rate, so the backlog converges while the system is alive.
--
-- AUDIENCE (the retroactive-growth fix): a viewer qualifies as "contacts" ONLY through a shared active
--   conversation that BOTH sides were already in when the post was created (both participant rows'
--   joined_at < status_posts.created_at) — posting to your contacts must not become visible to someone
--   you meet TOMORROW. Deny predicates (blocks, leaving) stay LIVE. Modes: 'contacts' (default) is
--   honored in commit 1; 'except'/'only' (status_audience + members) are enforced in commit 2.
--
-- status_views — commit 2 writes these (view recording + the owner's viewer list under the SAME
--   read-receipts reciprocity messages use); the feed's unseen_count reads them from day one.
--
-- Idempotent + transactional (fresh initdb volume AND an already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../082_status.sql
BEGIN;

CREATE TABLE IF NOT EXISTS status_posts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_user_id uuid NOT NULL REFERENCES users_auth(id) ON DELETE CASCADE,
  app_id uuid NOT NULL DEFAULT '00000000-0000-0000-0000-000000000001' REFERENCES apps(id),
  kind text NOT NULL CHECK (kind IN ('text', 'image', 'video')),
  body text,
  media_id uuid,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  deleted_at timestamptz,
  media_purged_at timestamptz
);

-- The feed's hot path: live posts per owner (partial — expired/deleted rows fall out of the index).
CREATE INDEX IF NOT EXISTS idx_status_posts_live
  ON status_posts (owner_user_id, expires_at) WHERE deleted_at IS NULL;

-- The sweep's pickup: expired, not yet purged (partial keeps it tiny).
CREATE INDEX IF NOT EXISTS idx_status_posts_sweep
  ON status_posts (expires_at) WHERE media_purged_at IS NULL AND deleted_at IS NULL;

-- The media-authz reverse lookup (purpose "status": media_id → owning post).
CREATE INDEX IF NOT EXISTS idx_status_posts_media
  ON status_posts (media_id) WHERE media_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS status_views (
  status_id uuid NOT NULL REFERENCES status_posts(id) ON DELETE CASCADE,
  viewer_user_id uuid NOT NULL,
  viewed_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (status_id, viewer_user_id)
);

-- Per-USER audience setting (WhatsApp: persisted, not per-post). Commit 1 honors 'contacts' only.
CREATE TABLE IF NOT EXISTS status_audience (
  user_id uuid PRIMARY KEY REFERENCES users_auth(id) ON DELETE CASCADE,
  mode text NOT NULL DEFAULT 'contacts' CHECK (mode IN ('contacts', 'except', 'only')),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- ONE list whose meaning is set by the mode ('except' = excluded contacts; 'only' = the explicit set).
CREATE TABLE IF NOT EXISTS status_audience_members (
  user_id uuid NOT NULL REFERENCES users_auth(id) ON DELETE CASCADE,
  member_user_id uuid NOT NULL REFERENCES users_auth(id) ON DELETE CASCADE,
  PRIMARY KEY (user_id, member_user_id)
);

COMMIT;
