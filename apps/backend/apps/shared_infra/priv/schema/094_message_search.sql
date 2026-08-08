-- 094: message_search — the search-only copy of message text (DECISION_LOG [2026-08-08]).
--
-- Scylla is the authoritative message store and has no text index of any kind; this table is what
-- serves GET /api/v1/search/messages after the cutover. It is NON-AUTHORITATIVE (never read for
-- message content — results are hydrated by point-reading the store), REBUILDABLE (from Scylla, by
-- conversation — MessageService.SearchBackfill), and DELETION-PROPAGATED (the search-index consumer
-- deletes the row on message.deleted.v1; hydration drops anything that slips through).
--
-- search_text is the FULL BODY, not a tsvector. DECISION_LOG [2026-08-02] measured that a tsvector
-- is not meaningfully less a copy ("the words are enough"), and tsvector matching breaks the
-- substring ILIKE contract both clients depend on. There is deliberately NO text index yet: the
-- current query volume is a seq scan over thousands of rows, same class as the ILIKE the old
-- messages-table search always ran. The recorded upgrade when it slows is pg_trgm GIN
-- (gin_trgm_ops), which preserves ILIKE semantics exactly — NOT tsvector, which does not.
--
-- sender_user_id and created_at are here because the per-viewer masking predicates
-- (VisibilityWindow: participant window, after-viewing) need them at query time. Masking is applied
-- at QUERY time only — an index row is conversation-global and the windows are per-viewer.
--
-- No foreign keys, deliberately: rows arrive from a Kafka consumer and a Scylla backfill, and must
-- not take locks on (or order themselves after) users/conversations writes.
CREATE TABLE IF NOT EXISTS message_search (
  message_id      uuid        PRIMARY KEY,
  conversation_id uuid        NOT NULL,
  sender_user_id  uuid        NOT NULL,
  created_at      timestamptz NOT NULL,
  search_text     text        NOT NULL
);

-- The query's access path: the caller's conversations first (participant join), newest first.
CREATE INDEX IF NOT EXISTS message_search_conversation_created_idx
  ON message_search (conversation_id, created_at DESC);
