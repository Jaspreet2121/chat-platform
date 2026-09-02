-- 115: View-once messages. The flag is MESSAGE metadata, not a media purpose — the SAME asset can be
-- an ordinary attachment in one message and view-once in another, so the property belongs to the
-- send, not to the blob.
--
-- Idempotent + transactional (fresh initdb volume AND already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../115_view_once.sql
BEGIN;

-- A REAL COLUMN, not a metadata key, for two reasons that both bite:
--   * the media-authz oracle is raw SQL against this table, so the flag must be indexable there;
--   * metadata is map<text,text> on Scylla, where a jsonb boolean arrives as the STRING "true" —
--     the exact type divergence that has already shipped in this repo twice.
-- DEFAULT false + NOT NULL: every existing row is explicitly not-view-once, and the column is inert
-- until a client sets it.
ALTER TABLE messages
  ADD COLUMN IF NOT EXISTS view_once boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN messages.view_once IS
  'View-once send (115). Immutable after create. Gates media download via view_once_opens; a false '
  'row takes the ordinary media path with no extra query.';

-- Per-recipient opens. Write-once by construction: no updated_at, no status column — the row IS the
-- fact, and it is irreversible.
--
-- DELIBERATELY NOT message_receipts. That table has two fixed timestamps and a SCALAR status, so a
-- user cannot be both read and opened; and its read state is PRIVACY-FILTERED (a reader with
-- receipts off appears delivered, never read). An open GATES ACCESS and must be recorded whether or
-- not the user hides read receipts — sharing the table would let a privacy setting suppress an
-- access-control fact.
--
-- PG-ONLY, on purpose: media authz is a Postgres read (MessageStore's media_download_allowed oracle
-- and this gate run against the same Repo). Mirroring opens into Scylla would add a second source of
-- truth for an authorization decision with no reader.
CREATE TABLE IF NOT EXISTS view_once_opens (
  message_id uuid NOT NULL,
  user_id uuid NOT NULL REFERENCES users_auth(id) ON DELETE CASCADE,
  conversation_id uuid NOT NULL,
  opened_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, user_id)
);

COMMENT ON TABLE view_once_opens IS
  'Write-once per-recipient view-once opens (115). The PK is the authorization question: has THIS '
  'user opened THIS message. Separate from message_receipts because an open is access control, not '
  'a privacy-filtered receipt.';

-- "Everything this user has opened", for a client reconciling state after a reinstall.
CREATE INDEX IF NOT EXISTS view_once_opens_user_idx
  ON view_once_opens (user_id, opened_at DESC);

-- The lazy-expiry scan: unopened view-once messages older than the window. PARTIAL on view_once so
-- the index stays proportional to the feature rather than to the whole messages table. `view_once`
-- is a plain column reference and therefore immutable — unlike a now() predicate, which Postgres
-- rejects outright in an index (learned in 114).
CREATE INDEX IF NOT EXISTS messages_view_once_created_idx
  ON messages (created_at) WHERE view_once;

COMMIT;
