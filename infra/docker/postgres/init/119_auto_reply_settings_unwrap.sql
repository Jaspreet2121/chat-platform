-- 119: Auto-reply settings — unwrap the DOUBLE-ENCODED jsonb blocks (2026-09-06).
--
-- The write path in UserService.AutoReplies ran `Jason.encode!(block)` and bound the resulting
-- STRING to a `$N::jsonb` parameter. Postgrex encodes a jsonb parameter with its own JSON encoder,
-- so the already-encoded text was encoded a SECOND time and stored as a jsonb *string* rather than
-- an object:
--
--   jsonb_typeof(away)      -> 'string'
--   away ->> 'enabled'      -> NULL          (every SQL-side read sees nothing)
--   (away #>> '{}')::jsonb  -> {"enabled": true, ...}   (the real block, one unwrap away)
--
-- The `'{}'::jsonb` defaults in the same INSERT are SQL literals, never parameters, so they were
-- stored correctly — which is why production held rows with a string `away` beside an object
-- `greeting` that had only ever been defaulted.
--
-- This backfill unwraps ONE level, per column INDEPENDENTLY, and only for columns that are actually
-- strings. Already-correct objects are untouched by the `jsonb_typeof = 'string'` predicate, which
-- is also what makes a second run a no-op: after the first pass those rows are objects.
--
-- The `LIKE '{%'` guard is deliberate: it restricts the unwrap to text that is a JSON OBJECT. A
-- string holding anything else is left alone rather than aborting the whole migration on a cast
-- error, and the read path logs a warning naming that user so it stays visible.
--
-- Idempotent + transactional (fresh initdb volume AND an already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../119_auto_reply_settings_unwrap.sql
BEGIN;

UPDATE auto_reply_settings
   SET away = (away #>> '{}')::jsonb
 WHERE jsonb_typeof(away) = 'string'
   AND (away #>> '{}') LIKE '{%';

UPDATE auto_reply_settings
   SET greeting = (greeting #>> '{}')::jsonb
 WHERE jsonb_typeof(greeting) = 'string'
   AND (greeting #>> '{}') LIKE '{%';

COMMIT;
