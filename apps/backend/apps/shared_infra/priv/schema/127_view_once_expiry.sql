-- 127: the VIEW-ONCE EXPIRY LEDGER — the row that makes the 14-day sweep possible at all.
--
-- WHAT WAS BROKEN. `ViewOnce.expired_unopened_media/0` selected `FROM messages`, which is EMPTY
-- under MESSAGE_STORE_ADAPTER=scylla (ScyllaAdapter.put_message opens a Postgres transaction only to
-- stage the outbox; no row is ever inserted). Production on 2026-09-20: 0 rows in `messages`, 0 with
-- view_once — and 10 rows in `view_once_opens`. The feature is in real use and the sweep had never
-- seen a single candidate. Unopened view-once blobs were never deleted, ever.
--
-- WHY A LEDGER RATHER THAN A STORE-CORRECT QUERY. The sweep needs "every unopened view-once message
-- older than 14 days" — a RANGE scan across conversations. Scylla answers point reads and
-- partition walks, not that. A small Postgres table indexed for exactly this question is the shape
-- the query wants, and it is also where `view_once_opens` already lives, so open-and-expire stay in
-- one store and one transaction.
--
-- sender_user_id IS LOAD-BEARING, not decoration. `MediaService.Media.purge_asset/1` is
-- owner-scoped (it refuses a purge whose expected owner does not match), and the old sweep payload
-- carried bare media ids — so even with rows it could not have deleted anything. Carrying the
-- sender here is the second half of the fix.
--
-- WRITE ORDER (message_store.ex): the row is inserted INSIDE the transaction that already stages
-- the outbox, BEFORE the authoritative Scylla put. A crash between the two therefore leaves a ROW
-- WITH NO BLOB — the sweep purges a media id that does not exist, which the media service answers
-- `{:ok, purged: false}` for, and the row is stamped. The reverse — a blob with no row — would be
-- an object nothing can ever reclaim, and this ordering makes it unreachable.
--
-- purged_at IS STAMPED ONLY AFTER A SUCCESSFUL PURGE. Stamping first is precisely how the status
-- sweep leaked 22 blobs in September 2026 (statuses.ex, "the stamp now MEANS blob confirmed gone").
-- An unstamped row is retried on every sweep until it is gone.
--
-- NO BACKFILL IS POSSIBLE. View-once messages sent before this migration exist only in Scylla and
-- have no ledger row, so they can never be swept. Reconstructing them would mean a full scan of
-- every conversation partition to find a boolean, and the blobs are already past their window with
-- no reader. Stated in docs/05-api-contracts/message-service.md; going forward is enough.
--
-- Idempotent + transactional (fresh initdb volume AND an already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../127_view_once_expiry.sql
BEGIN;

CREATE TABLE IF NOT EXISTS view_once_expiry (
  -- One row per view-once MESSAGE. The PK is what the open path deletes by, and what makes the
  -- ledger write idempotent under an idempotent send (107 replays the same client_msg_id).
  message_id uuid PRIMARY KEY,
  conversation_id uuid NOT NULL,
  media_id uuid NOT NULL,
  -- The purge's expected owner. Without it the sweep cannot delete anything (see above).
  sender_user_id uuid NOT NULL,
  app_id uuid NOT NULL DEFAULT '00000000-0000-0000-0000-000000000001' REFERENCES apps(id),
  -- created_at + 14 days, materialised at write time so a later change to the window cannot move
  -- the deadline of media a recipient is already looking at.
  expires_at timestamptz NOT NULL,
  -- NULL = still owed a purge. Set = the blob is CONFIRMED gone.
  purged_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- THE SWEEP'S ONLY ACCESS PATH: unpurged rows past their deadline, oldest first. Partial on
-- purged_at IS NULL so the index stays proportional to the WORK OUTSTANDING rather than to every
-- view-once message ever sent.
CREATE INDEX IF NOT EXISTS view_once_expiry_due_idx
  ON view_once_expiry (expires_at) WHERE purged_at IS NULL;

COMMENT ON TABLE view_once_expiry IS
  'View-once expiry ledger (127). Written before the Scylla put, deleted on first open, swept in '
  'batches. Replaces a SELECT over `messages`, which is empty under the Scylla store.';

COMMIT;
