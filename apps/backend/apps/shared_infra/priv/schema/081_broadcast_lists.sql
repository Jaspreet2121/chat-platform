-- Feature: BROADCAST LISTS — a saved recipient set owned by ONE user. Sending fans out N INDEPENDENT
-- direct messages into N ordinary DMs (resolved through the SAME find_or_create_direct entry point a
-- normal first message uses — no second key derivation). A broadcast list is NOT a conversation: no
-- shared thread, no shared read state, and a recipient's message is byte-identical to a hand-typed DM
-- (no broadcast_id anywhere on the wire — metadata is recipient-visible, so the sender's client joins
-- its own copies locally from the send response).
--
-- Members: a HARD-deleted user prunes automatically (FK CASCADE — delete_user hard-deletes users_auth);
-- a SUSPENDED user is filtered at send time, NOT pruned (suspension is reversible; pruning would
-- silently rewrite the owner's list).
--
-- Caps (enforced in the domain, carried in the error): 256 members/list, 32 lists/user.
--
-- Idempotent + transactional (fresh initdb volume AND an already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../081_broadcast_lists.sql
BEGIN;

CREATE TABLE IF NOT EXISTS broadcast_lists (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_user_id uuid NOT NULL REFERENCES users_auth(id) ON DELETE CASCADE,
  app_id uuid NOT NULL DEFAULT '00000000-0000-0000-0000-000000000001' REFERENCES apps(id),
  name text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- The owner's lists (the CRUD read + the per-user list cap count).
CREATE INDEX IF NOT EXISTS idx_broadcast_lists_owner ON broadcast_lists (owner_user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS broadcast_list_members (
  list_id uuid NOT NULL REFERENCES broadcast_lists(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES users_auth(id) ON DELETE CASCADE,
  added_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (list_id, user_id)
);

COMMIT;
