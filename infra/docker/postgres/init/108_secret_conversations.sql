-- 108: Secret chats — the opt-in E2EE flag. ONE column: a secret conversation's message CONTENT is
-- sealed client-side (the 107 device keys are the trust root) and the server stores/relays opaque
-- ciphertext only; every server-side content reader (search index, webhook payloads, push previews,
-- inbox previews, the auto-reply engine) gates on this flag or on the sealed message type. Normal
-- conversations are byte-identical to before. Enabling is ONE-WAY in v1.
--
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../108_secret_conversations.sql
BEGIN;

ALTER TABLE conversations ADD COLUMN IF NOT EXISTS secret boolean NOT NULL DEFAULT false;

COMMIT;
