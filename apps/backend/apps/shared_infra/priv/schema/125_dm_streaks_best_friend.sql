-- 125: BEST FRIENDS — server-authoritative DM streaks + the per-user best-friend pin.
--
-- WHY THE SERVER OWNS THE STREAK. Android computes it locally today, from whatever history that
-- device holds: the same DM reads 4 on one handset and 6 on another, because a device that joined
-- late or pruned old rows simply counts fewer days. A streak is a shared fact about a pair of
-- people, so it is maintained once, here, and read by every device.
--
-- THE RULE: a day counts when BOTH sides sent at least one message during it. Consecutive counted
-- days increment; a gap resets to 1 at the next counted day. "Day" is the SENDER's local calendar
-- day (their tz offset when the client sends one, else UTC) — documented in
-- docs/05-api-contracts/conversation-service.md.
--
--   dm_streaks               — one row per DIRECT conversation. Groups never get a row.
--   conversation_participants.last_message_on — the date each member last sent in that conversation.
--       This is what makes "did BOTH sides message today?" a single indexed read instead of a scan
--       over `messages` — which under the Scylla store would read a FROZEN, effectively empty table
--       and answer "no" forever.
--   conversation_participants.best_friend_at  — the per-user pin, mirroring pinned_at/archived_at
--       from migration 076. On the participant row on purpose: a user cannot pin a conversation they
--       are not in (there is no row to set), and "has the OTHER member pinned me back?" is the same
--       table, one join. At most one per user, enforced in the domain (a new pin clears the old).
--
-- Idempotent: IF NOT EXISTS throughout, safe on a fresh initdb volume and a running database.
BEGIN;

CREATE TABLE IF NOT EXISTS dm_streaks (
  conversation_id uuid PRIMARY KEY REFERENCES conversations(id) ON DELETE CASCADE,
  streak_days integer NOT NULL DEFAULT 0 CHECK (streak_days >= 0),
  -- The last day BOTH sides sent. NULL = never counted. Compared against the sender's local today,
  -- so the increment/reset decision is one date arithmetic, not a scan.
  last_both_sides_date date,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE conversation_participants ADD COLUMN IF NOT EXISTS last_message_on date;
ALTER TABLE conversation_participants ADD COLUMN IF NOT EXISTS best_friend_at timestamptz;

-- The mutual-pin check reads ONLY pinned rows; partial, like 076's.
CREATE INDEX IF NOT EXISTS conversation_participants_best_friend_idx
  ON conversation_participants (user_id) WHERE best_friend_at IS NOT NULL;

COMMIT;
