-- Feature 128: MESSAGE REQUESTS — a first message from a STRANGER lands in a separate bucket the
-- recipient must accept before the chat joins their normal life.
--
--   request_pending_at — NULL = a normal conversation. Set = this participant has NOT yet accepted;
--                        the chat is EXCLUDED from their default inbox list and fetched separately
--                        via ?scope=requests, it does NOT push, it does NOT badge, and it does NOT
--                        count as a shared conversation for presence / status / profile audiences.
--                        Accept clears it. Decline clears it AND writes a user_blocks row.
--
-- PER-PARTICIPANT, on the RECIPIENT's own row, exactly the precedent 076 set for archived_at and 060
-- before it. Only the recipient's row is ever stamped: the SENDER's side is a normal conversation
-- from the moment they send, which is what makes "the sender sees delivered as today" true without a
-- second code path.
--
-- NOT conversations.status, deliberately. That column is conversation-GLOBAL, so it cannot express
-- "pending for the recipient, sent for the sender", and 35 call sites across 14 files filter on it.
--
-- Idempotent + transactional (fresh initdb volume AND an already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -v ON_ERROR_STOP=1 \
--     < infra/docker/postgres/init/128_message_requests.sql
BEGIN;

ALTER TABLE conversation_participants ADD COLUMN IF NOT EXISTS request_pending_at timestamptz;

-- The requests list ("what is pending for me?") reads ONLY pending rows, and pending rows are a tiny
-- minority of any user's participant set — a partial index keeps that list cheap without bloating the
-- common accepted case. Mirrors conversation_participants_pinned_idx (076) exactly. The DEFAULT inbox
-- list needs no index of its own: it rides the existing conversation_participants(user_id) index and
-- tests request_pending_at IS NULL on rows it has already fetched.
CREATE INDEX IF NOT EXISTS conversation_participants_request_pending_idx
  ON conversation_participants (user_id) WHERE request_pending_at IS NOT NULL;

COMMIT;
