-- Web-push (Phase 1): per-browser push subscriptions + a one-time read-model backfill.
--
-- push_subscriptions: one row per browser installation (endpoint is globally unique). Owned by the
-- auth service (a subscription is a device credential); the notification service READS it to deliver
-- VAPID-signed web-push for message.created fan-outs. ON DELETE CASCADE with the account.
--
-- BACKFILL (cold-start fix): the notification service's conversation_participants_readmodel only
-- learns membership from conversation.events.v1 — which never flowed while Kafka was off. Seed it
-- from the authoritative conversation_participants so EXISTING conversations fan out immediately at
-- Kafka enablement. Idempotent (ON CONFLICT DO NOTHING; fresh initdb = no-op on empty tables).
--
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../061_push_subscriptions.sql
BEGIN;

CREATE TABLE IF NOT EXISTS push_subscriptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users_auth(id) ON DELETE CASCADE,
  endpoint text NOT NULL UNIQUE,
  p256dh text NOT NULL,
  auth text NOT NULL,
  user_agent text,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_used_at timestamptz
);

CREATE INDEX IF NOT EXISTS push_subscriptions_user_idx ON push_subscriptions (user_id);

-- Cold-start backfill: seed the notification read-model from live membership.
INSERT INTO conversation_participants_readmodel
  (conversation_id, user_id, active, role, last_event_at, updated_at)
SELECT cp.conversation_id, cp.user_id, (cp.left_at IS NULL), cp.role, cp.joined_at, now()
FROM conversation_participants cp
ON CONFLICT (conversation_id, user_id) DO NOTHING;

COMMIT;
