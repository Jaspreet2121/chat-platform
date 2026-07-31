-- Feature: PHONE DISCOVERABILITY OPT-OUT — the "who can find me by phone number" setting deferred by
-- the contacts slice (its 4-step plan lived in ContactController's moduledoc; this is that plan).
--
--   discoverable_by_phone — BOOLEAN, deliberately not the everyone/contacts/nobody vocabulary: phone
--   discovery is by definition performed by a NON-contact (an existing contact already shares a
--   conversation and can see you), so a "contacts" tier would be a no-op dressed as a choice. Two
--   meaningful values ⇒ a boolean is the honest shape.
--
--   DEFAULT TRUE — anything else silently breaks discovery for every existing user. NULL/no row reads
--   as true everywhere (the `IS NOT FALSE` predicate).
--
-- Enforced inside the auth phone lookups themselves (lookup_active_by_phone/2 + lookup_active_by_phones/2
-- gain one LEFT JOIN), so single by-phone, bulk contacts sync, AND call-add-by-phone share ONE SQL
-- predicate and cannot drift. A non-discoverable user is ABSENT — identical to an unknown number / a
-- non-match — never an error (no existence reveal). Username lookup stays deliberately OUTSIDE this
-- setting (a handle is opt-in and exists to be found).
--
-- Idempotent + transactional (fresh initdb volume AND an already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../084_phone_discoverability.sql
BEGIN;

ALTER TABLE user_privacy_settings
  ADD COLUMN IF NOT EXISTS discoverable_by_phone boolean NOT NULL DEFAULT true;

COMMIT;
