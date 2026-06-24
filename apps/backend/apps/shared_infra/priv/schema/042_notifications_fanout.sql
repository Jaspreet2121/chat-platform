-- Recipient fan-out (cross-service sub-slice c): notification-service now writes ONE
-- notification per CONVERSATION PARTICIPANT (resolved from the local
-- conversation_participants_readmodel), not one per event.
--
-- recipient_user_id = who is being notified (vs sender_user_id = who sent the message).
-- The UNIQUE index on (source_event_id, recipient_user_id) is the durable per-recipient
-- idempotency guard: insert_all(... on_conflict: :nothing) makes redelivery / retry safe
-- and a participant set that grew between deliveries adds only the new recipients. The
-- notification_processed_events ledger remains the coarse event-level gate.

ALTER TABLE notifications ADD COLUMN IF NOT EXISTS recipient_user_id uuid;

CREATE UNIQUE INDEX IF NOT EXISTS notifications_source_event_recipient_uidx
  ON notifications (source_event_id, recipient_user_id);
