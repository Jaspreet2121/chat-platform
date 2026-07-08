-- Feature: Call links (L1) — a reusable, WhatsApp-style link that, when someone joins, spins up a
-- conversation-LESS call (calls.kind='link', conversation_id NULL). Registered users only (auth reused).
--
-- ADDITIVE + fully guarded so re-running is a no-op:
--   * new `call_links` table (its `id` IS the url-safe link code; no conversation_id)
--   * calls.link_id (nullable text) — ties a live 'link' call back to its call_links row
--   * calls.kind CHECK extended to allow 'link' (direct/group unchanged)
--
-- calls.conversation_id is ALREADY nullable (066 declares it `uuid` with no NOT NULL), so link calls (no
-- conversation) fit the existing column with no ALTER. calls.status already allows 'ongoing' (068), which a
-- link call uses. group_call_participants (067) is reused for link participants (status 'joined').
--
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../069_call_links.sql
BEGIN;

-- A reusable call link. `id` IS the url-safe link code (the PK). No conversation_id — a link call has none.
CREATE TABLE IF NOT EXISTS call_links (
  id text PRIMARY KEY,
  creator_id uuid NOT NULL,
  type text NOT NULL CHECK (type IN ('voice', 'video')),
  require_approval boolean NOT NULL DEFAULT false,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Links a creator owns, newest first.
CREATE INDEX IF NOT EXISTS idx_call_links_creator ON call_links(creator_id, created_at DESC);

-- Tie a live 'link' call back to its call_links row. Nullable — direct/group calls never set it.
ALTER TABLE calls ADD COLUMN IF NOT EXISTS link_id text;

-- Find the active call for a link fast (the find-or-create join path queries by link_id).
CREATE INDEX IF NOT EXISTS idx_calls_link_id ON calls(link_id) WHERE link_id IS NOT NULL;

-- Extend calls.kind to allow 'link' (drop the 068 check, re-add with the extra value). Idempotent.
ALTER TABLE calls DROP CONSTRAINT IF EXISTS calls_kind_check;
ALTER TABLE calls ADD CONSTRAINT calls_kind_check CHECK (kind IN ('direct', 'group', 'link'));

COMMIT;
