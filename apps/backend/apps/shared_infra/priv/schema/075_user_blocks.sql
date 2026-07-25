-- Feature: user blocking (Tier-2 safety, first-party). A per-user, DIRECTIONAL relationship: blocker →
-- blocked. Blocking is 1-on-1 and exists independently of any conversation (you can block a user found by
-- phone before ever chatting), so this is a user-pair table, not conversation-scoped.
--
-- Owned by conversation-service (ConversationService.Blocks): the HOTTEST enforcement — the per-message send
-- gate (Participants.authorize_send) — already runs there, so co-locating the block data makes that check a
-- LOCAL indexed query (no cross-service round-trip, no cache). realtime-gateway (calls/presence) and the
-- gateway (profile/endpoints) have no Repo and reach it through SharedInfra.ConversationClient. Reports, by
-- contrast, live with the existing moderation reads in auth-service.
--
-- PK on (blocker, blocked) makes a block idempotent (re-block is a no-op ON CONFLICT), gives a fast "does
-- blocker block blocked?" AND a fast "everyone blocker has blocked" (leading column). The extra index on
-- blocked_user_id serves the REVERSE direction ("who has blocked me") used by the symmetric either-direction
-- check. CHECK forbids a self-block at the storage layer (the endpoint also 400s it).
--
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../075_user_blocks.sql
BEGIN;

CREATE TABLE IF NOT EXISTS user_blocks (
  blocker_user_id uuid NOT NULL REFERENCES users_auth(id) ON DELETE CASCADE,
  blocked_user_id uuid NOT NULL REFERENCES users_auth(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (blocker_user_id, blocked_user_id),
  CONSTRAINT user_blocks_no_self CHECK (blocker_user_id <> blocked_user_id)
);

-- Reverse-direction lookup ("who has blocked this user"): the forward direction is covered by the PK's
-- leading column, so only the reverse needs its own index.
CREATE INDEX IF NOT EXISTS user_blocks_blocked_idx ON user_blocks (blocked_user_id);

COMMIT;
