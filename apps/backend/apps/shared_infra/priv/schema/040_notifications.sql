-- notification-service tables (the FIRST of the 5 documented-only services to be built).
--
-- Per-service idempotency ledger: notification-service owns its OWN ledger
-- (notification_processed_events), it does NOT share message-service's processed_events.
-- This avoids coupling two services through one table (the shared-database anti-pattern)
-- and is the blueprint each future service copies: <service>_processed_events in that
-- service's own Repo. Keyed (consumer, event_id) so the dedupe core is identical to the
-- message-service projection and supports multiple internal consumers later.
--
-- notifications is notification-service's domain data. This first slice creates ONE
-- record per message.created.v1 event (proving the service end-to-end); recipient
-- fan-out (one row per conversation participant) is deferred — message.created.v1 carries
-- the SENDER, not recipients, so fan-out needs ConversationService participant data.
-- NO cross-service FKs.

CREATE TABLE IF NOT EXISTS notification_processed_events (
  consumer text NOT NULL,
  event_id uuid NOT NULL,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (consumer, event_id)
);

CREATE TABLE IF NOT EXISTS notifications (
  id uuid PRIMARY KEY,
  type text NOT NULL,
  source_event_id uuid NOT NULL,
  conversation_id uuid,
  message_id uuid,
  sender_user_id uuid,
  read boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL,
  inserted_at timestamptz NOT NULL DEFAULT now()
);
