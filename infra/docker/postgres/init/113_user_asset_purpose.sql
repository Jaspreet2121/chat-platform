-- 113: user_asset purpose — server-generated, user-owned media with no conversation of its own.
-- Today that is exactly one thing: the UPI QR PNG the server renders and stores on the user's
-- profile (upi_qr_media_id).
--
-- WHY IT EXISTS. Those rows were minted as purpose='message' with conversation_id NULL, because
-- "message" is what lets an asset be sent into a chat — the /qr slash command sends the QR by id as
-- an ordinary media message. That worked, but it made the SERVER the last producer of anchorless
-- 'message' rows, blocking the rule that 'message' must carry a conversation anchor. A QR has no
-- conversation to give, so it needed its own purpose rather than an exemption from that rule.
--
-- THE ACL IS UNCHANGED. media_authz routes 'user_asset' to the SAME predicate as 'message' (owner
-- short-circuit, then the message oracle), because a recipient of a sent QR fetches this very
-- media_id. This migration is therefore behaviour-neutral for every row it touches — which is what
-- makes the backfill below safe.
--
-- Idempotent + transactional (fresh initdb volume AND already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../113_user_asset_purpose.sql
BEGIN;

ALTER TABLE media_assets DROP CONSTRAINT IF EXISTS media_assets_purpose_check;
ALTER TABLE media_assets ADD CONSTRAINT media_assets_purpose_check
  CHECK (purpose IN ('message', 'user_avatar', 'group_avatar', 'status', 'sealed_media', 'user_asset'));

-- BACKFILL the QRs generated before this purpose existed (~15 rows in production).
--
-- The predicate is deliberately narrow and all three clauses are load-bearing:
--   * object_key LIKE '%upi-qr.png' — UpiQr.MediaWriter hardcodes that filename, so this identifies
--     the generator, not a guess about content.
--   * conversation_id IS NULL — a QR never had one. This is what refuses to touch a real attachment
--     that merely happens to be named upi-qr.png (a user CAN upload a file with that name).
--   * purpose = 'message' — only rows the old writer produced; re-running this changes nothing.
--
-- Rows that are already 'user_asset' are skipped, so this is safe to replay.
UPDATE media_assets
SET purpose = 'user_asset',
    updated_at = now()
WHERE purpose = 'message'
  AND conversation_id IS NULL
  AND object_key LIKE '%upi-qr.png';

COMMIT;
