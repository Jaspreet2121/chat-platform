-- Feature: /v1 message-list cursor pagination — compound (created_at, message_id) keyset.
--
-- The SDK's reconnect-backfill pages GET /v1/conversations/:id/messages forward (after_*) and backward
-- (before_*) on the tuple (created_at, message_id). The existing index idx_messages_conversation_created_at
-- is only (conversation_id, created_at DESC) — a PREFIX that lacks the message_id tiebreak, so a
-- same-timestamp keyset would sort/heap-filter. This index adds message_id as the trailing key so the
-- keyset scan is fully index-ordered in BOTH directions (recent/backward read forward; forward reads
-- backward). The older 2-col index is left in place (harmless; this one supersedes it for the timeline).
--
-- Additive + idempotent (IF NOT EXISTS). No table rewrite; safe to run online.
--
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../071_messages_keyset_index.sql

CREATE INDEX IF NOT EXISTS idx_messages_conversation_created_msg
  ON messages (conversation_id, created_at DESC, message_id DESC);
