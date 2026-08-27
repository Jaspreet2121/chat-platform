-- 111: E2EE calls (LiveKit client-side frame encryption). The CALLER generates a random 32-byte call
-- key, seals it per-device with crypto_box_seal (the SAME primitive and the SAME registry device keys
-- as E2EE_FRAME.md §3 message envelopes), and both sides feed the raw key to LiveKit's key provider.
-- The SFU routes already-encrypted frames; the server NEVER sees the key. See E2EE_FRAME.md §calls.
--
-- Three columns, and the split between them is the point:
--
--   * e2ee_offer  (jsonb, NULLABLE) — the opaque sealed envelopes. Persisted ONLY so a callee woken by
--     a push can fetch the call state and still find its envelope (envelopes never ride the push
--     payload — FCM size limits). SCRUBBED TO NULL when the call reaches a terminal state: the key
--     died with the call, so a retained envelope is pure liability with no use. The server validates
--     the object's SHAPE only and never parses envelope_b64.
--
--   * e2ee (boolean, NOT NULL DEFAULT false) — an offer was made. SURVIVES the scrub; this is what
--     call history reads to draw the lock badge on a past call.
--
--   * e2ee_accepted (boolean, NULLABLE) — the callee confirmed it opened its envelope. Also survives.
--     NULL means "never answered" (a missed/cancelled call carries no media, so the mode is moot);
--     false means the two sides agreed to run PLAIN. Mode is a CLIENT agreement — the server only
--     carries these bits and never enforces or downgrades.
--
-- Old clients are unaffected: a call created with no offer leaves e2ee false and e2ee_offer NULL,
-- which is byte-for-byte the pre-E2EE row.
--
-- No new index: these are read on rows already selected by primary key (state fetch) or by the
-- existing per-user (caller_id/callee_id, created_at DESC) history indexes.
--
-- Idempotent + transactional (fresh initdb volume AND already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../111_calls_e2ee.sql
BEGIN;

ALTER TABLE calls ADD COLUMN IF NOT EXISTS e2ee_offer jsonb;
ALTER TABLE calls ADD COLUMN IF NOT EXISTS e2ee boolean NOT NULL DEFAULT false;
ALTER TABLE calls ADD COLUMN IF NOT EXISTS e2ee_accepted boolean;

COMMIT;
