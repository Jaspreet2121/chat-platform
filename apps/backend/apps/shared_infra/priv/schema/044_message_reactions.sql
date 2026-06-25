-- Message reactions: ONE reaction per user per message (WhatsApp model), changeable in place.
--
-- Idempotent so it applies to BOTH a fresh initdb volume (auto-run) AND an already-running database
-- (run manually to avoid recreating the volume / losing local data):
--   docker compose -f docker-compose.prod.yml exec -T postgres psql -U chat_user -d chat_platform -c \
--     "CREATE TABLE IF NOT EXISTS message_reactions (conversation_id uuid NOT NULL, message_id uuid NOT NULL, user_id uuid NOT NULL, emoji text NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (message_id, user_id)); CREATE INDEX IF NOT EXISTS idx_message_reactions_message ON message_reactions (message_id);"
CREATE TABLE IF NOT EXISTS message_reactions (
  conversation_id uuid NOT NULL,
  message_id uuid NOT NULL,
  user_id uuid NOT NULL,
  emoji text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_message_reactions_message ON message_reactions (message_id);
