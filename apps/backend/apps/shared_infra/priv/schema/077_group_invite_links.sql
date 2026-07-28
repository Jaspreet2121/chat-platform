-- Feature: Group invite links — a shareable, WhatsApp-style link that lets someone JOIN a group without
-- being added by the owner. Mirrors call_links (069): the row's `code` IS the url-safe link code (PK).
--
-- One ACTIVE link per conversation (a partial unique index enforces it), so "reset link" = revoke + mint
-- and there is never ambiguity about which code is live. Revoking sets active=false (the row stays for
-- audit); a join with a revoked/unknown code is a plain 404. NO expiry (WhatsApp default) — revoke/reset
-- is the control. `app_id` is denormalised from the conversation so a code only resolves WITHIN its tenant
-- (a cross-tenant join is a clean 404). `created_by` is the owner who minted it.
--
-- Joining goes through the SAME participant-insert + participant_added event + conversation_updated
-- broadcast as an owner add, so the inbox row / unread / fan-out are identical (see ConversationService.
-- InviteLinks). A user with a left_at row was REMOVED (the only writer of left_at is the owner remove
-- path — there is no voluntary leave), so a link-join refuses them rather than readmitting.
--
-- ADDITIVE + fully guarded so re-running is a no-op (fresh initdb volume AND an already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../077_group_invite_links.sql
BEGIN;

CREATE TABLE IF NOT EXISTS group_invite_links (
  code text PRIMARY KEY,
  conversation_id uuid NOT NULL,
  app_id uuid NOT NULL,
  created_by uuid NOT NULL,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Exactly ONE active link per conversation (the invariant) — and the fast "find the active link for this
-- group" lookup that create-idempotency, reset, and revoke all use. Lookup-by-code is the PK. Revoked rows
-- (active=false) are exempt, so a conversation keeps its link history without ever having two live codes.
CREATE UNIQUE INDEX IF NOT EXISTS group_invite_links_active_conversation_idx
  ON group_invite_links (conversation_id) WHERE active;

COMMIT;
