-- C6 (Scylla write-ahead intent): the outbox status set gains two states.
--   'staged'  — durable INTENT written BEFORE the authoritative Scylla put; invisible to the
--               dispatcher (claim_due selects pending/delivering only). Promoted to 'pending' after
--               the put lands, or resolved by MessageService.WebhookOutboxSweeper.
--   'aborted' — a staged row whose message provably never landed. KEPT AND MARKED, never deleted:
--               it is evidence a write was attempted and lost. Operators:
--                 SELECT * FROM webhook_outbox WHERE status = 'aborted';
--               last_error says why; after verifying the message truly never landed, the row IS the
--               record — or re-drive manually by setting status='pending' if the message was
--               repaired into existence.
-- The same-transaction 'pending' path (Postgres store) is untouched.
--
-- Idempotent + transactional:
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../087_webhook_outbox_staged.sql
BEGIN;

ALTER TABLE webhook_outbox DROP CONSTRAINT IF EXISTS webhook_outbox_status_check;
ALTER TABLE webhook_outbox ADD CONSTRAINT webhook_outbox_status_check
  CHECK (status IN ('pending', 'delivering', 'delivered', 'failed', 'staged', 'aborted'));

COMMIT;
