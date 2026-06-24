-- notification-service LOCAL participant read-model, built from conversation.events.v1
-- (conversation.participant_added.v1 / participant_removed.v1). Lets (c) fan-out resolve
-- a conversation's recipients WITHOUT a sync call to ConversationService.
--
-- Correctness (two independent mechanisms — see DECISION_LOG):
--   * DEDUPE same-event redelivery via notification_processed_events (consumer
--     'notification-participants', event_id).
--   * LAST-WRITER-WINS convergence for DIFFERENT events under out-of-order delivery: an
--     update is applied ONLY when the incoming occurred_at >= the stored last_event_at.
-- Soft state (active boolean), NEVER hard-deleted: a late add after a remove is not lost,
-- and a remove arriving before its add just creates an inactive row. NO cross-service FKs.

CREATE TABLE IF NOT EXISTS conversation_participants_readmodel (
  conversation_id uuid NOT NULL,
  user_id uuid NOT NULL,
  active boolean NOT NULL,
  role text,
  last_event_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (conversation_id, user_id)
);

-- (c) fan-out reads the active set for a conversation.
CREATE INDEX IF NOT EXISTS conversation_participants_readmodel_active_idx
  ON conversation_participants_readmodel (conversation_id)
  WHERE active;
