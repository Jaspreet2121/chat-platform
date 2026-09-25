-- 133: REPAIR audit_logs.metadata rows that were stored double-encoded.
--
-- The audit writer passed Jason.encode!(map) to a parameter cast `$5::jsonb`. That cast makes
-- Postgrex type the parameter as jsonb and JSON-encode whatever it is handed, so the already-encoded
-- string was stored as a JSON *string* — `"{\"reason\":\"...\"}"` — and every `metadata->>'reason'`
-- read back NULL. The writer now passes the map (2026-09-25). This turns the rows already written
-- back into the objects they were meant to be.
--
-- Idempotent: only rows whose top-level value is a JSON string are touched, and only when that
-- string looks like a JSON object, so a re-run finds nothing to do and an odd row cannot fail the
-- migration. Nothing is deleted; a row this does not recognise is left exactly as it is.

UPDATE audit_logs
SET metadata = (metadata #>> '{}')::jsonb
WHERE jsonb_typeof(metadata) = 'string'
  AND (metadata #>> '{}') ~ '^\s*\{';
