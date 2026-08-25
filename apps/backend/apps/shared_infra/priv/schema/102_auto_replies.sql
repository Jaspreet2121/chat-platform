-- Auto-replies (102, 2026-08-26): Away message + Greeting message, WhatsApp Business model.
-- Everything defaults to DISABLED — the feature is behaviourally invisible until a user enables it.
--
--   * auto_reply_settings — its OWN table, not a profile jsonb: the engine reads it on every inbound
--     1:1 message (hot path, narrow row beats the ever-wider profile), and away/greeting evolve as
--     jsonb without schema churn. One row per user; absent row = both features off.
--   * auto_reply_log — the at-least-once dedupe ledger: one row per auto-reply actually sent.
--     Rolling windows (24 h away throttle, greeting resend_after_days) cannot be a unique index,
--     so race-safety is a pg_advisory_xact_lock around check+insert (see UserService.AutoReplies).
--
-- Idempotent + transactional (fresh initdb volume AND an already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../102_auto_replies.sql
BEGIN;

CREATE TABLE IF NOT EXISTS auto_reply_settings (
  user_id uuid PRIMARY KEY REFERENCES users_auth(id) ON DELETE CASCADE,
  app_id uuid NOT NULL,
  away jsonb NOT NULL DEFAULT '{}'::jsonb,
  greeting jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS auto_reply_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id uuid NOT NULL,
  user_id uuid NOT NULL REFERENCES users_auth(id) ON DELETE CASCADE,
  conversation_id uuid NOT NULL,
  kind text NOT NULL CHECK (kind IN ('away', 'greeting')),
  sent_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS auto_reply_log_window_idx
  ON auto_reply_log (user_id, conversation_id, kind, sent_at DESC);

COMMIT;
