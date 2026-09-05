-- Feature: ad-hoc conversationless group calls (picker rings 2+ contacts, NO conversation created).
--
-- ONE change: calls.kind gains 'adhoc'. An adhoc call is an N-party call whose membership is ONLY its
-- group_call_participants rows — like 'link' (069) it has NO conversation_id and NO single callee, but
-- unlike 'link' it is invite-driven: the initiator names targets and every target is validated
-- (exists + active + SAME app + not blocked either direction) BEFORE any ring
-- (ConversationService.CallStore.create_adhoc_group_call).
--
-- WHY A NEW KIND rather than kind='group' with NULL conversation: every membership-derived group rule
-- (join's member list, add's ensure_can_add, the ongoing-call banner) silently mis-handles a NULL
-- conversation — join would collapse to :call_invalid before the participant-row arm is consulted. A
-- distinct kind makes each downstream arm an explicit, testable decision instead of an implicit crash.
--
-- Idempotent DROP/ADD, exactly the 069 pattern — safe to re-run on a live table.
BEGIN;

ALTER TABLE calls DROP CONSTRAINT IF EXISTS calls_kind_check;
ALTER TABLE calls ADD CONSTRAINT calls_kind_check
  CHECK (kind IN ('direct', 'group', 'link', 'adhoc'));

COMMIT;
