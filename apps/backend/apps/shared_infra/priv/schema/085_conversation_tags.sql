-- Feature: CONVERSATION TAGS — user-defined lists (WhatsApp "Lists"). A user creates named tags and
-- assigns their OWN conversations to them, then filters the inbox by one. Server-side because archive
-- and pin (076) are already per-participant backend prefs: tags are the same kind of state — per-user,
-- per-conversation, must survive reinstall and reach web. A local-only version would be inconsistent
-- with its own neighbours and force a migration later.
--
-- A tag is PRIVATE to its owner. Nothing here is ever visible to another participant: the assignment
-- table carries no user column at all, because the tag it points at already owns it — per-user
-- isolation therefore cannot drift out of sync with itself.
--
-- LEFT CONVERSATIONS KEEP THEIR TAGS, exactly as archive/pin do. Leaving sets
-- conversation_participants.left_at and never clears archived_at/pinned_at; the inbox join filters
-- `cp.left_at IS NULL`, so the prefs go dormant and revive on rejoin. Assignments behave the same way,
-- so there is no cleanup path and no special case.
--
-- Caps (enforced in the domain, carried in the error): 20 tags per user, 50 chars per name. A
-- conversation may hold SEVERAL tags — that is what makes these lists rather than folders — bounded
-- naturally by the 20-tag cap, so no second cap exists.
--
-- Idempotent + transactional (fresh initdb volume AND an already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../085_conversation_tags.sql
BEGIN;

CREATE TABLE IF NOT EXISTS conversation_tags (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_user_id uuid NOT NULL REFERENCES users_auth(id) ON DELETE CASCADE,
  app_id uuid NOT NULL DEFAULT '00000000-0000-0000-0000-000000000001' REFERENCES apps(id),
  name text NOT NULL,
  -- Case-folded name, for CASE-INSENSITIVE per-owner uniqueness (the usernames precedent): "Work" and
  -- "work" would be indistinguishable as chips in the filter row. A case-only rename keeps this key,
  -- so it is free.
  name_key text NOT NULL,
  -- An opaque client palette token. The server validates LENGTH only and never interprets it — the
  -- column exists now because adding it later is a migration.
  color text,
  -- Display order in the filter row. Ties break on created_at.
  position integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Per-owner name uniqueness, case-insensitive. Scoped to the OWNER, not the tenant: tags are private,
-- so two users in the same app may both have a "Work".
CREATE UNIQUE INDEX IF NOT EXISTS conversation_tags_owner_name_key
  ON conversation_tags (owner_user_id, name_key);

-- The owner's tag list (the CRUD read + the per-user cap count).
CREATE INDEX IF NOT EXISTS conversation_tags_owner_idx
  ON conversation_tags (owner_user_id, position, created_at);

CREATE TABLE IF NOT EXISTS conversation_tag_assignments (
  tag_id uuid NOT NULL REFERENCES conversation_tags(id) ON DELETE CASCADE,
  conversation_id uuid NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  assigned_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tag_id, conversation_id)
);

-- THE INBOX PATH. Every inbox row runs a lateral "which of MY tags is this conversation in?" — that
-- lookup is by conversation_id, which the primary key (tag_id, conversation_id) cannot serve. Without
-- this index the inbox degrades to a sequential scan of the assignment table per row.
CREATE INDEX IF NOT EXISTS conversation_tag_assignments_conversation_idx
  ON conversation_tag_assignments (conversation_id);

COMMIT;
