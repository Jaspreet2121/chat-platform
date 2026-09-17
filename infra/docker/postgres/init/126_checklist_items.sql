-- 126: CHECKLIST messages ("to-do list") — the MUTABLE per-item state of a checklist MESSAGE.
--
-- MIRRORS POLLS (079) EXACTLY, and for the same reasons. The checklist DEFINITION — the items the
-- author typed, with server-generated stable ids, plus others_can_check / others_can_add — lives in
-- the message's `metadata.checklist` JSON: it fans out and loads WITH the message, and the items an
-- author created are immutable. Only what CHANGES needs a table.
--
-- A row here exists for an item only once something has happened to it:
--   * a TICK   — done/done_by/done_at for an item that lives in the definition (text/position NULL);
--   * an ADDED item — text + position set, because an added item is NOT in the definition JSON
--     (rewriting the stored message to append one would mean editing a message in place, which this
--     codebase does not do for poll definitions either).
--
-- The aggregate (items + done_count + total) is ALWAYS computed from the definition plus these rows
-- at fetch time — the `checklist_updated` broadcast is an optimization, never the source of truth.
-- A client that misses the frame and refetches history sees identical state. Same contract as polls.
--
-- OPTIMISTIC CONCURRENCY lives on `done_at`: a tick carries the done_at it believes is current, and
-- the UPDATE matches on it. Two people tapping the same item cannot flip-flop — the loser is told
-- (409) and re-renders, rather than silently overwriting.
--
-- CAPS, enforced here as far as the schema can:
--   * item text ≤ 200 characters — a CHECK, so no code path can store a longer one;
--   * ≤ 30 items per message — `position` is bounded 1..30 and UNIQUE per message, which bounds the
--     ADDED items structurally. The total (definition + added) is enforced in the domain, where the
--     definition count is known.
--
-- Idempotent + transactional (fresh initdb volume AND an already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../126_checklist_items.sql
BEGIN;

CREATE TABLE IF NOT EXISTS checklist_items (
  message_id uuid NOT NULL,
  item_id text NOT NULL,
  conversation_id uuid NOT NULL,
  -- Set ONLY on an added item (an item the definition does not carry). NULL on a tick row.
  text text CHECK (text IS NULL OR char_length(text) BETWEEN 1 AND 200),
  position integer CHECK (position IS NULL OR (position >= 1 AND position <= 30)),
  done boolean NOT NULL DEFAULT false,
  done_by uuid,
  -- NULL while not done. The optimistic-concurrency token: a tick states the value it expects.
  done_at timestamptz,
  app_id uuid NOT NULL DEFAULT '00000000-0000-0000-0000-000000000001' REFERENCES apps(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, item_id)
);

-- Bounds the ADDED items to 30 per message structurally (NULLs — the tick rows — do not collide).
CREATE UNIQUE INDEX IF NOT EXISTS checklist_items_position_key
  ON checklist_items (message_id, position) WHERE position IS NOT NULL;

COMMIT;
