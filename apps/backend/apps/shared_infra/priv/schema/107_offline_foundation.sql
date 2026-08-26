-- 107: Offline messaging foundation — device key registry + client-message-id dedup ledger.
--
-- device_keys: one row per (user, device) with the device's PUBLIC keys (ed25519 sign +
-- x25519 agreement, 32 bytes each). Bound to device_sessions.device_id (the session's device
-- identity, never client-claimed); re-upload rotates in place. Public keys only — nothing secret
-- is ever stored, and the fetch endpoint is membership-gated at the store.
--
-- message_client_ids: the idempotent-send ledger. Message ids stay SERVER-generated timeuuids
-- (Scylla clustering order = server receipt order — client ids can never reorder history), so
-- dedup lives here: (app, conversation, sender, client_msg_id) → the message_id minted for the
-- FIRST write. A resend under the same key returns that message; downstream (webhook outbox,
-- kafka events, auto-replies, unread) never re-fires because the create short-circuits before the
-- store. Rows expire after 30 days via an opportunistic sweep on the write path.
--
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../107_offline_foundation.sql
BEGIN;

CREATE TABLE IF NOT EXISTS device_keys (
  user_id uuid NOT NULL REFERENCES users_auth(id) ON DELETE CASCADE,
  device_id text NOT NULL,
  app_id uuid NOT NULL REFERENCES apps(id),
  ed25519_public bytea NOT NULL CHECK (octet_length(ed25519_public) = 32),
  x25519_public bytea NOT NULL CHECK (octet_length(x25519_public) = 32),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, device_id)
);

CREATE TABLE IF NOT EXISTS message_client_ids (
  app_id uuid NOT NULL,
  conversation_id uuid NOT NULL,
  sender_user_id uuid NOT NULL,
  client_msg_id uuid NOT NULL,
  message_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (app_id, conversation_id, sender_user_id, client_msg_id)
);

-- The 30d sweep ranges on age.
CREATE INDEX IF NOT EXISTS message_client_ids_created_idx ON message_client_ids (created_at);

COMMIT;
