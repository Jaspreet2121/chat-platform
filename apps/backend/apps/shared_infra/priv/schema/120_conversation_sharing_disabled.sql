-- Feature: "restrict sharing" — the conversation's members agree its messages are not to be
-- forwarded out of it.
--
-- ONE boolean on conversation_settings, beside the wallpaper (117): NOT NULL DEFAULT false, so
-- every existing conversation reads as unrestricted with no backfill. The client hides the toggle
-- while the key is ABSENT from the conversation detail, so false and absent are deliberately
-- different wire shapes — the read is what turns the feature on.
--
-- Authorization mirrors the wallpaper's exactly: a DM's either participant, a group's owner/admin.
-- Enforcement is server-side on the FORWARD path (MessageService.Messages refuses a forward whose
-- declared source conversation is restricted); everything else about this setting is friction.
BEGIN;

ALTER TABLE conversation_settings
  ADD COLUMN IF NOT EXISTS sharing_disabled boolean NOT NULL DEFAULT false;

COMMIT;
