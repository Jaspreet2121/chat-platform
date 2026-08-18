-- Feature: QR-linked web/desktop clients (2026-08-18) — WhatsApp's "Linked devices" model.
--
-- device_sessions.linked_by_device_id: the PHONE device that approved the QR link, NULL for a
-- session created by a direct login (the primary). This is the provenance column the two new rules
-- read: the Linked-devices list shows which phone linked a web session, and revocation is
-- asymmetric — the phone may revoke its linked devices, but a linked device may never revoke a
-- primary (NULL-linked_by) session. text to match device_sessions.device_id (not a uuid).
--
-- No index: every read of this column rides the existing (user_id, device_id) unique index or a
-- per-user list that already scans the user's handful of rows.
--
-- Idempotent + transactional (fresh initdb volume AND an already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../099_device_sessions_linked_by.sql
BEGIN;

ALTER TABLE device_sessions ADD COLUMN IF NOT EXISTS linked_by_device_id text;

COMMIT;
