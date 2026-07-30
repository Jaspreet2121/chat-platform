-- Feature: POLLS (Tier-3) — per-user votes on a poll MESSAGE. The poll DEFINITION (question, options with
-- server-generated stable ids, allows_multiple) lives in the message's metadata JSON (§7 convention, like
-- media/location/call): it is immutable (no poll editing) and fans out/loads with the message. Only the
-- mutable per-user state — votes — needs a table, mirroring message_reactions exactly.
--
-- One row per (message, user, option). Multi-choice polls hold several rows per user; single-choice is a
-- SEMANTIC enforced transactionally in the domain (every vote write REPLACES the user's whole vote set for
-- that message), so the row shape never changes with the poll type. The PK's btree prefix (message_id)
-- serves per-message aggregation — no extra index needed (unlike reactions, whose PK starts elsewhere).
--
-- Aggregates are ALWAYS computed from these rows at fetch time (history) — the poll_updated broadcast is an
-- optimization, never the source of truth. Votes are HISTORY: a participant who leaves keeps their rows
-- (the membership gate stops them voting again), exactly like receipts.
--
-- Idempotent + transactional (fresh initdb volume AND an already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../079_poll_votes.sql
BEGIN;

CREATE TABLE IF NOT EXISTS poll_votes (
  conversation_id uuid NOT NULL,
  message_id uuid NOT NULL,
  user_id uuid NOT NULL,
  option_id text NOT NULL,
  app_id uuid NOT NULL DEFAULT '00000000-0000-0000-0000-000000000001' REFERENCES apps(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, user_id, option_id)
);

COMMIT;
