-- Feature: "disappearing messages" made PERMANENT per user. Previously the disappearing rules (rolling
-- auto-delete window + "after viewing") were purely a live viewer read-filter, so turning the setting OFF
-- un-hid already-disappeared messages. This table MATERIALIZES a permanent per-user hidden marker: at
-- fetch time, any message that currently meets the disappear condition gets a marker (idempotent). The
-- read filter then hides a message if a marker exists — so once gone, it stays gone for that user, and
-- turning the setting off only stops hiding FUTURE messages.
--
-- Still SOFT-HIDE only: this is a separate per-user index; the messages row is never touched, and the
-- admin content viewer (which passes NO viewer_user_id) neither materializes nor filters — admins see
-- every message. Nothing is ever hard-deleted.
--
--   user_hidden_messages(user_id, message_id, hidden_at) — one row per (user, permanently-hidden message).
--
-- Idempotent + transactional (fresh initdb volume AND already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../065_user_hidden_messages.sql
BEGIN;

CREATE TABLE IF NOT EXISTS user_hidden_messages (
  user_id uuid NOT NULL,
  message_id uuid NOT NULL,
  hidden_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, message_id)
);

COMMIT;
