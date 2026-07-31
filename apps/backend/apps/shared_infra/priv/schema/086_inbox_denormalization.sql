-- Feature: DENORMALISED INBOX ROW — the inbox stops computing preview/unread from the messages table
-- and reads maintained columns instead. This is the store-agnostic prerequisite for the Scylla port
-- (the @inbox_sql laterals were §0.5's cross-service dependency on messages), and it pays for itself
-- today: the inbox is the app's most-used screen, and every message send already ran both laterals
-- once per recipient to build the conversation_updated frames.
--
-- THE SPLIT (deliberate): preview facts are CONVERSATION-GLOBAL — per-user variation is a read-time
-- MASK computed from the participant's own prefs (cleared_before / auto_delete window), because the
-- newest message is always the LAST to leave any window. Only the unread counter is per-participant.
-- Raw fields (body/type/content_type) are stored, not rendered text, so the existing Elixir
-- preview_text/message_kind mapping stays the single place that logic lives.
--
--   conversations.last_message_*        — newest NON-DELETED message's raw preview fields
--   conversation_participants.unread_count      — maintained counter (see below for its honesty rules)
--   conversation_participants.oldest_unread_at  — trustworthiness watermark for the auto-delete window:
--       a counter is provably fresh iff auto_delete is off OR oldest_unread_at is inside the window.
--       Stale-but-safe BY DESIGN: mark_read does NOT advance it (advancing would need a store read per
--       receipt to find the next-oldest unread); an old watermark merely fails the freshness test and
--       triggers a read-time recount that repairs the row. The one free advance: count hitting 0 NULLs it.
--
-- Idempotent + transactional (fresh initdb volume AND an already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../086_inbox_denormalization.sql
BEGIN;

ALTER TABLE conversations ADD COLUMN IF NOT EXISTS last_message_id uuid;
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS last_message_at timestamptz;
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS last_message_body text;
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS last_message_type text;
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS last_message_content_type text;
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS last_message_sender_id uuid;

ALTER TABLE conversation_participants ADD COLUMN IF NOT EXISTS unread_count integer NOT NULL DEFAULT 0;
ALTER TABLE conversation_participants ADD COLUMN IF NOT EXISTS oldest_unread_at timestamptz;

-- ---------------------------------------------------------------------------------------------------
-- BACKFILL (safe to re-run: recomputes from source truth; new columns only).
-- The newest non-deleted message per conversation. Per-user windows are NOT applied here — they are
-- read-time masks, matching the semantics argument above.
UPDATE conversations c
SET last_message_id = lm.message_id,
    last_message_at = lm.created_at,
    last_message_body = lm.body,
    last_message_type = lm.message_type,
    last_message_content_type = lm.metadata->>'content_type',
    last_message_sender_id = lm.sender_user_id
FROM (
  SELECT DISTINCT ON (conversation_id)
         conversation_id, message_id, created_at, body, message_type, metadata, sender_user_id
  FROM messages
  WHERE deleted_at IS NULL
  ORDER BY conversation_id, created_at DESC
) lm
WHERE lm.conversation_id = c.id;

-- Per-participant unread: exactly today's lateral, run once as a backfill. Left rows get 0 (they are
-- invisible to the inbox and recounted on rejoin anyway).
UPDATE conversation_participants cp
SET unread_count = agg.unread,
    oldest_unread_at = agg.oldest
FROM (
  SELECT cp2.conversation_id, cp2.user_id,
         count(m.message_id)::int AS unread,
         min(m.created_at) AS oldest
  FROM conversation_participants cp2
  LEFT JOIN messages m
    ON m.conversation_id = cp2.conversation_id
   AND m.deleted_at IS NULL
   AND m.sender_user_id <> cp2.user_id
   AND (cp2.cleared_before IS NULL OR m.created_at > cp2.cleared_before)
   AND (cp2.auto_delete_seconds IS NULL
        OR m.created_at > now() - make_interval(secs => cp2.auto_delete_seconds))
   AND NOT EXISTS (
     SELECT 1 FROM message_receipts r
     WHERE r.conversation_id = m.conversation_id AND r.message_id = m.message_id
       AND r.user_id = cp2.user_id AND (r.status = 'read' OR r.read_at IS NOT NULL)
   )
  WHERE cp2.left_at IS NULL
  GROUP BY cp2.conversation_id, cp2.user_id
) agg
WHERE agg.conversation_id = cp.conversation_id AND agg.user_id = cp.user_id;

COMMIT;
