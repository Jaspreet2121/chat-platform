-- Postgres-backed message store (durability behind MESSAGE_STORE_ADAPTER=postgres).
--
-- ScyllaDB remains the documented long-term high-write message backend (see
-- DECISION_LOG); this table provides real durability now via the swappable
-- MessageStore adapter boundary. It deliberately carries NO cross-service foreign
-- keys (message_id / conversation_id / sender_user_id are plain UUIDs owned by
-- the message-service Repo), keeping the message store self-contained.

CREATE TABLE IF NOT EXISTS messages (
  message_id uuid PRIMARY KEY,
  conversation_id uuid NOT NULL,
  sender_user_id uuid NOT NULL,
  message_type text NOT NULL,
  body text,
  media_id uuid,
  reply_to_message_id uuid,
  status text NOT NULL DEFAULT 'active',
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  edited_at timestamptz,
  deleted_at timestamptz
);

CREATE INDEX IF NOT EXISTS idx_messages_conversation_created_at
  ON messages (conversation_id, created_at DESC);

CREATE TABLE IF NOT EXISTS message_receipts (
  conversation_id uuid NOT NULL,
  message_id uuid NOT NULL,
  user_id uuid NOT NULL,
  status text NOT NULL,
  delivered_at timestamptz,
  read_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (conversation_id, message_id, user_id)
);
