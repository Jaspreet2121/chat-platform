-- Starred / bookmarked messages: per-user, private (no realtime). One star per (user, message).
--
-- Idempotent so it applies to BOTH a fresh initdb volume (auto-run) AND an already-running database
-- (run manually to avoid recreating the volume / losing local data):
--   docker compose -f docker-compose.prod.yml exec -T postgres psql -U chat_user -d chat_platform -c \
--     "CREATE TABLE IF NOT EXISTS starred_messages (user_id uuid NOT NULL, message_id uuid NOT NULL, conversation_id uuid NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (user_id, message_id)); CREATE INDEX IF NOT EXISTS idx_starred_messages_user_created ON starred_messages (user_id, created_at DESC);"
CREATE TABLE IF NOT EXISTS starred_messages (
  user_id uuid NOT NULL,
  message_id uuid NOT NULL,
  conversation_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, message_id)
);

CREATE INDEX IF NOT EXISTS idx_starred_messages_user_created ON starred_messages (user_id, created_at DESC);
