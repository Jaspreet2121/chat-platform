-- Event-driven projections + the reusable idempotency ledger (Kafka consumers).
--
-- processed_events is the dedupe ledger keyed by (consumer, event_id): each consumer
-- records the events it has applied, so at-least-once redelivery is made exactly-once.
-- The dedupe insert + the projection write happen in ONE transaction (see
-- MessageService.Projections.ConversationSummary). NO cross-service FKs — these are
-- owned by message-service's own Repo (single self-contained store).
--
-- This is the blueprint future consumers (e.g. notification-service) copy verbatim:
-- a (consumer, event_id) ledger + an atomic idempotent upsert.

CREATE TABLE IF NOT EXISTS processed_events (
  consumer text NOT NULL,
  event_id uuid NOT NULL,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (consumer, event_id)
);

CREATE TABLE IF NOT EXISTS conversation_message_summaries (
  conversation_id uuid PRIMARY KEY,
  message_count bigint NOT NULL DEFAULT 0,
  last_message_id uuid,
  last_message_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now()
);
