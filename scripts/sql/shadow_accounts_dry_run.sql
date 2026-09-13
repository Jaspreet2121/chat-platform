-- DRY RUN for migration 123 — the SAME candidate + exclusion logic, NO DELETE. Read-only: the temp
-- tables are dropped at the end of the transaction. Run this first, read the NOTICEs, then confirm.
BEGIN;

DO $$
DECLARE
  -- Rows created on/after this date are not shadows: a verify in flight at migration time has an
  -- account row before its session row. Fixed, so a re-run sweeps nothing new.
  cutoff constant timestamptz := '2026-09-13 00:00:00+00';
  fk record;
  soft record;
  candidates integer;
  excluded integer;
  deleted integer := 0;
BEGIN
  DROP TABLE IF EXISTS shadow_candidates;
  DROP TABLE IF EXISTS shadow_excluded;

  -- SHADOW = active, never verified (no device_sessions row, ever), no profile, phone/email
  -- account (NOT a v1 integrator end-user: those carry external_id and legitimately never have a
  -- session), created before the cutoff.
  CREATE TEMP TABLE shadow_candidates ON COMMIT DROP AS
  SELECT ua.id
  FROM users_auth ua
  WHERE ua.status = 'active'
    AND ua.external_id IS NULL
    AND ua.created_at < cutoff
    AND NOT EXISTS (SELECT 1 FROM user_profiles up WHERE up.user_id = ua.id)
    AND NOT EXISTS (SELECT 1 FROM device_sessions ds WHERE ds.user_id = ua.id);

  CREATE TEMP TABLE shadow_excluded (id uuid, reason text) ON COMMIT DROP;

  -- EXCLUSION 1: every HARD foreign key to users_auth(id), enumerated from the catalog at run
  -- time — a table added after this file was written is covered automatically.
  FOR fk IN
    SELECT c.conrelid::regclass::text AS tbl, a.attname::text AS col
    FROM pg_constraint c
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
    WHERE c.contype = 'f' AND c.confrelid = 'users_auth'::regclass
  LOOP
    EXECUTE format(
      'INSERT INTO shadow_excluded SELECT c.id, %L FROM shadow_candidates c '
      || 'WHERE EXISTS (SELECT 1 FROM %s x WHERE x.%I = c.id)',
      fk.tbl || '.' || fk.col, fk.tbl, fk.col
    );
  END LOOP;

  -- EXCLUSION 2: SOFT references — user-id columns with no FK (message-store and read-model
  -- tables). Enumerated from the schema files on 2026-09-13; a soft reference cannot be found
  -- in the catalog, so this list is the one thing that needs updating when such a column is added.
  FOR soft IN
    SELECT * FROM (VALUES
    ('calls', 'callee_id'),
    ('calls', 'caller_id'),
    ('conversation_participants_readmodel', 'user_id'),
    ('group_call_participants', 'user_id'),
    ('group_invite_links', 'created_by'),
    ('inbox_read_marks', 'user_id'),
    ('invites', 'inviter_user_id'),
    ('message_client_ids', 'sender_user_id'),
    ('message_reactions', 'user_id'),
    ('message_receipts', 'user_id'),
    ('message_search', 'sender_user_id'),
    ('messages', 'sender_user_id'),
    ('notifications', 'sender_user_id'),
    ('poll_votes', 'user_id'),
    ('starred_messages', 'user_id'),
    ('status_views', 'viewer_user_id'),
    ('user_hidden_messages', 'user_id'),
    ('username_holds', 'user_id')
    ) AS s(tbl, col)
  LOOP
    IF to_regclass(soft.tbl) IS NOT NULL THEN
      EXECUTE format(
        'INSERT INTO shadow_excluded SELECT c.id, %L FROM shadow_candidates c '
        || 'WHERE EXISTS (SELECT 1 FROM %I x WHERE x.%I = c.id)',
        soft.tbl || '.' || soft.col, soft.tbl, soft.col
      );
    END IF;
  END LOOP;

  SELECT count(*) INTO candidates FROM shadow_candidates;
  SELECT count(DISTINCT id) INTO excluded FROM shadow_excluded;

  RAISE NOTICE '123: % shadow candidate(s); % excluded because referenced', candidates, excluded;
  FOR soft IN SELECT reason, count(*) AS n FROM shadow_excluded GROUP BY reason ORDER BY n DESC LOOP
    RAISE NOTICE '123:   excluded % row(s) — referenced by %', soft.n, soft.reason;
  END LOOP;

  -- DRY RUN: no DELETE. The number that WOULD be deleted:
  RAISE NOTICE '123 DRY RUN: would delete % shadow account(s) (candidates minus excluded)', candidates - excluded;
END $$;

ROLLBACK;
