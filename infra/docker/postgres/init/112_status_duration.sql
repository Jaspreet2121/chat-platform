-- 112: per-user STATUS DURATION. Until now expiry was a fixed 24h: status_posts.expires_at is written
-- at INSERT as `now() + 24h` and every read filters `expires_at > now()`. This makes the 24 a
-- per-user preference (6/12/24/48) while leaving both of those mechanisms exactly as they are.
--
-- WHY THIS COLUMN LIVES ON status_audience. That table is already the per-user STATUS PREFERENCES row
-- (PRIMARY KEY user_id, `mode`, `updated_at`) — it is named for the only preference it held when 082
-- shipped. Adding a second per-user status table would mean two rows, two upserts and two places to
-- look for "this user's status settings"; extending the existing row keeps one. The name is now
-- narrower than its contents, which is the lesser evil and is recorded here rather than renamed (a
-- rename would touch every audience query for no behavioural gain).
--
-- NOT RETROACTIVE, BY CONSTRUCTION. The column is read only when a post is CREATED; expires_at is
-- already materialised on each row, so changing this setting cannot move the expiry of anything
-- already posted. That is deliberate: shortening your duration must not make statuses your contacts
-- are already looking at vanish out from under them.
--
-- The CHECK is the server-owned enum the API validates against and returns to clients, so the picker
-- is rendered from the server rather than hardcoded. Widening it later is an ALTER here plus the
-- module attribute in MessageService.Statuses — both, or the DB refuses the write.
--
-- Idempotent + transactional (fresh initdb volume AND an already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../112_status_duration.sql
BEGIN;

ALTER TABLE status_audience
  ADD COLUMN IF NOT EXISTS duration_hours integer NOT NULL DEFAULT 24;

-- Drop + re-add so re-running the migration after the enum widens is a clean no-op (068/097 pattern).
ALTER TABLE status_audience DROP CONSTRAINT IF EXISTS status_audience_duration_hours_check;
ALTER TABLE status_audience ADD CONSTRAINT status_audience_duration_hours_check
  CHECK (duration_hours IN (6, 12, 24, 48));

COMMIT;
