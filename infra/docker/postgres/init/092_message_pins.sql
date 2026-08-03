-- Feature: PINNED MESSAGES — a conversation shows up to 3 pinned messages above the transcript.
--
-- NOT THE SAME THING AS A PINNED CONVERSATION. `conversation_participants.pinned_at` (076) is a
-- PER-USER inbox preference that sorts a chat to the top of YOUR list. This table is a
-- PER-CONVERSATION reference to a MESSAGE, visible to every participant. Two features, one word.
-- The table is named `message_pins` (not `pinned_messages`) so it does not read like the 076 column.
--
-- Per-conversation, deliberately: a pin only one person can see is a bookmark, and bookmarks already
-- exist as `starred_messages`.
--
-- WHO CAN PIN is enforced in the app, not here: owner+admin in groups (the tier that owns group
-- profile and settings — a shared-view mutation), either participant in a direct chat. It is NOT the
-- owner-only tier; that is reserved for membership changes.
--
-- Capped at 3 per conversation, enforced server-side. No expiry column: unpinning is one tap and the
-- cap displaces stale pins on its own. Adding expiry later is a nullable column plus a NULL-safe
-- predicate, so deferring costs almost nothing.
--
-- ---------------------------------------------------------------------------------------------------
-- THE PINNED SET IS GLOBAL; THE PINNED LIST A USER RECEIVES IS MASKED PER USER.
--
-- TWO PEOPLE IN THE SAME GROUP CAN LEGITIMATELY SEE DIFFERENT PINNED BARS. That is not a bug.
--
-- IF YOU REMOVE THAT MASK YOU WILL RESURRECT MESSAGES A USER CLEARED, OR THAT AUTO-DELETED FOR THEM,
-- OR THAT THEY DELETED FOR THEMSELVES — showing them the text of a message they cannot open. A pin is
-- per-conversation, but `cleared_before`, the rolling `auto_delete_seconds` window and
-- `user_hidden_messages` are all per-user, and a pin does not override any of them.
--
-- The same mistake already shipped once in message search, which returned hits for cleared and
-- auto-deleted messages until it was fixed. The mask reuses MessageService.VisibilityWindow, which
-- exists so this predicate has exactly one definition.
-- ---------------------------------------------------------------------------------------------------
--
-- Idempotent + transactional (fresh initdb volume AND an already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../092_message_pins.sql
BEGIN;

CREATE TABLE IF NOT EXISTS message_pins (
  conversation_id uuid NOT NULL REFERENCES conversations (id) ON DELETE CASCADE,
  message_id      uuid NOT NULL REFERENCES messages (message_id) ON DELETE CASCADE,
  pinned_by       uuid NOT NULL REFERENCES users_auth (id) ON DELETE CASCADE,
  pinned_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (conversation_id, message_id)
);

-- The cap count ("how many does this conversation have?") and the newest-first pinned list both read
-- one conversation's rows.
CREATE INDEX IF NOT EXISTS message_pins_conversation_idx
  ON message_pins (conversation_id, pinned_at DESC);

-- NOTE ON DELETION: messages are SOFT-deleted (status='deleted'), so the FK CASCADE above only fires
-- on a hard delete and is a backstop, not the mechanism. The unpin-on-delete write path is what keeps
-- the cap honest, and the read filter (`status <> 'deleted'`) is what guarantees a missed write path
-- can never resurrect tombstoned content. Both, deliberately — the same invariant
-- `media_by_conversation.deleted` carries: a projection is never evidence a message is live.

COMMIT;
