-- Feature: ARCHIVE + PIN conversations — per-participant inbox preferences on the CALLER's own
-- conversation_participants row, exactly the precedent 060 set for cleared_before / auto_delete_seconds.
-- Both are soft, per-user, reversible; nothing is deleted, and neither touches the other participants.
--
--   archived_at — NULL = normal. Set = the chat is EXCLUDED from the default inbox list (fetched separately
--                 via ?archived=true). A new message does NOT unarchive it (WhatsApp semantics). Independent
--                 of muted_until — archiving never mutes.
--   pinned_at   — NULL = normal. Set = the chat sorts ABOVE the rest (pinned-first, newest-activity within).
--                 Capped at 3 pins per user, enforced server-side. Independent of archived_at.
--
-- Idempotent + transactional (fresh initdb volume AND an already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../076_conversation_archive_pin.sql
BEGIN;

ALTER TABLE conversation_participants ADD COLUMN IF NOT EXISTS archived_at timestamptz;
ALTER TABLE conversation_participants ADD COLUMN IF NOT EXISTS pinned_at timestamptz;

-- The pin-cap count ("how many has this user pinned?") and the pinned-first inbox ordering read ONLY pinned
-- rows — a partial index keeps both cheap without bloating the common unpinned case. The archived-filter list
-- rides the existing conversation_participants(user_id) index (a user's participant set is small).
CREATE INDEX IF NOT EXISTS conversation_participants_pinned_idx
  ON conversation_participants (user_id) WHERE pinned_at IS NOT NULL;

COMMIT;
