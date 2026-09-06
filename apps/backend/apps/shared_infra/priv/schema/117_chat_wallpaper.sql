-- Feature: shared chat wallpaper — one participant sets it, both sides see it.
--
-- ONE nullable jsonb on conversation_settings. Shape (validated in
-- ConversationService.Participants.set_wallpaper, whitelist-only):
--   {kind: "pattern"|"scene"|"solid"|"gradient", id?, background?, intensity?, dim?, color?}
-- NULL = unset (client falls back to its local default). NO backfill — every existing
-- conversation simply has no shared wallpaper yet.
--
-- kind="photo" is deliberately NOT storable: photos stay device-local. A shared photo would need
-- an upload + a cross-participant read ACL — explicitly out of scope; the server 422s it.
BEGIN;

ALTER TABLE conversation_settings ADD COLUMN IF NOT EXISTS wallpaper jsonb;

COMMIT;
