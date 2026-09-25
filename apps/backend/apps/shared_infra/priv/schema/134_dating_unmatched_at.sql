-- 134: UNMATCH IS A FLAG, NOT A DELETE.
--
-- The admin Matches surface shows "active or unmatched". Until now Dating.unmatch/1 DELETED the
-- dating_matches row, so there was nothing to show: the console reported every row as active and
-- said so. Now an unmatch sets unmatched_at and the row stays. Every user-facing read — the deck,
-- the matches list, the mutual-match check, the message-request bypass — filters unmatched_at IS
-- NULL, so nothing a user sees changes; only the history survives for safety and legal review.
--
-- The pair key must allow a pair to match AGAIN after an unmatch, so the unique index becomes
-- PARTIAL over live rows. Idempotent: the column is added IF NOT EXISTS; the old full index is
-- dropped only if it is still the non-partial one; the partial index is created IF NOT EXISTS.

ALTER TABLE dating_matches ADD COLUMN IF NOT EXISTS unmatched_at timestamptz;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_index i
    JOIN pg_class c ON c.oid = i.indexrelid
    WHERE c.relname = 'dating_matches_pair_key' AND i.indpred IS NULL
  ) THEN
    DROP INDEX dating_matches_pair_key;
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS dating_matches_pair_key
  ON dating_matches (app_id, user_low_id, user_high_id)
  WHERE unmatched_at IS NULL;

CREATE INDEX IF NOT EXISTS dating_matches_unmatched_idx
  ON dating_matches (app_id, unmatched_at) WHERE unmatched_at IS NOT NULL;
