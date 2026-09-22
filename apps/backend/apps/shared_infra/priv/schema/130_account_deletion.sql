-- Feature 130: SELF-SERVE ACCOUNT DELETION (App Store guideline 5.1.1(v), Play Data safety).
--
-- A user deleting their own account leaves a TOMBSTONE rather than a hole. The row in `users_auth`
-- survives with its id, its identity columns scrubbed and `deleted_at` set; everything personal
-- hangs off it and is deleted for real.
--
-- WHY NOT A HARD DELETE, which is what the admin path does. Three reasons, and the first is the one
-- that decides it:
--
--   1. MESSAGES OTHER PEOPLE RECEIVED ARE THEIR MESSAGES. WhatsApp's rule, and the one this product
--      follows: deleting your account does not reach into someone else's chat history. Those rows
--      carry a sender_user_id. Hard-deleting the identity orphans it, and an orphaned id renders as
--      nothing at all — no name, no "Deleted account", just a blank. A tombstone is what lets the
--      recipient's client say who it was from.
--   2. Three columns reference users_auth NOT NULL with no ON DELETE action — conversations.created_by,
--      media_assets.owner_user_id, call_sessions.started_by. The admin path reassigns them to the
--      acting root. A SELF-delete has no other actor to reassign to, and inventing one would put a
--      stranger's name on a group the deleted user created.
--   3. The phone number must become reusable immediately (the user may re-register), which a NULL in
--      the PARTIAL unique index on (app_id, phone_number) achieves without deleting anything.
--
-- `status` already carries 'deleted' in its CHECK (010) and Sessions.active_user/1 admits only
-- 'active', so setting it is what ends every session that is mid-flight. `deleted_at` is the
-- separate, honest record of WHEN — status is a state machine an admin also writes to (suspend,
-- ban, reactivate) and it cannot answer "was this a self-deletion, and on what date" for a
-- retention policy that has to.
--
-- Idempotent + transactional (fresh initdb volume AND an already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -v ON_ERROR_STOP=1 \
--     < infra/docker/postgres/init/130_account_deletion.sql
BEGIN;

ALTER TABLE users_auth ADD COLUMN IF NOT EXISTS deleted_at timestamptz;

-- THE IDENTITY CHECK HAS TO LEARN ABOUT TOMBSTONES. It currently reads
--   phone_number IS NOT NULL OR email IS NOT NULL OR external_id IS NOT NULL
-- (050), which is correct for a live account and impossible for a deleted one: scrubbing the phone
-- and the email is the whole point, and `external_id` is the partner API's resolve-or-create key —
-- writing a sentinel into it would make a tombstone resolvable by any partner who guessed the value.
-- A fourth branch keeps the constraint meaningful for live rows and satisfiable for dead ones.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'users_auth_identity_check') THEN
    ALTER TABLE users_auth DROP CONSTRAINT users_auth_identity_check;
  END IF;

  ALTER TABLE users_auth
    ADD CONSTRAINT users_auth_identity_check
    CHECK (
      phone_number IS NOT NULL
      OR email IS NOT NULL
      OR external_id IS NOT NULL
      OR deleted_at IS NOT NULL
    );
END $$;

-- The retention sweep's read ("which tombstones are past their window?"). Partial: tombstones are a
-- rounding error against the live table and always will be.
CREATE INDEX IF NOT EXISTS users_auth_deleted_at_idx
  ON users_auth (deleted_at) WHERE deleted_at IS NOT NULL;

COMMIT;
