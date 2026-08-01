-- Feature: FAVOURITE CONTACTS — the server side of the Calls tab's favourites (slice 59 shipped
-- device-local DataStore, deliberately v1; the cost surfaced as monogram chips, the disease is a
-- list that dies on reinstall and never reaches web). Same state class as archive/pin (076) and
-- conversation tags (085): per-user, small, ordered, must survive reinstall and reach every device.
--
-- A favourite points at a USER, not a conversation. The user-lifecycle decisions are REUSED, not
-- re-litigated: a hard-DELETED favourite prunes automatically (FK CASCADE — broadcast_list_members'
-- decision); a SUSPENDED one is filtered at read, never pruned (broadcast send's decision —
-- suspension is reversible, pruning would silently rewrite the list). A BLOCKED favourite REMAINS,
-- redacted by ProfilePresenter like every other surface — blocks never delete relationships here.
--
-- Cap: 20 per user (a chips row), position user-controlled (chips are placed by intent; implicit
-- recency would reshuffle them underfoot). Enforced in the domain, carried in the error.
--
-- Idempotent + transactional (fresh initdb volume AND an already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../090_favourite_contacts.sql
BEGIN;

CREATE TABLE IF NOT EXISTS favourite_contacts (
  owner_user_id uuid NOT NULL REFERENCES users_auth(id) ON DELETE CASCADE,
  favourite_user_id uuid NOT NULL REFERENCES users_auth(id) ON DELETE CASCADE,
  app_id uuid NOT NULL DEFAULT '00000000-0000-0000-0000-000000000001' REFERENCES apps(id),
  position integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (owner_user_id, favourite_user_id)
);

-- The owner's ordered list (the read + the cap count).
CREATE INDEX IF NOT EXISTS favourite_contacts_owner_idx
  ON favourite_contacts (owner_user_id, position, created_at);

COMMIT;
