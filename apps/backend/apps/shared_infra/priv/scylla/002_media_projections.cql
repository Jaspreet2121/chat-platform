-- Media projections for the Scylla port (C3 of the ladder). NOTHING READS THESE until C4 ports the
-- media trio (get_by_media_id / media_download_allowed / list_media) — this file exists so C4
-- implements against a deployed, shape-verified schema instead of an assumed one.
--
-- AUTHORITY AND THE SOFT-DELETE INVARIANT (write this down once, here, so C4 implements a stated
-- rule instead of rediscovering the hazard):
--   * messages_by_conversation is THE AUTHORITY. Both tables below are derived projections,
--     rebuildable from it at any time.
--   * media_by_conversation.deleted is a DENORMALISED COPY of the authority's tombstone. A failed
--     delete fan-out therefore leaves a tombstoned item still rendering in the gallery until
--     repaired. The projection reconciler (C4) OWNS convergence; readers must treat `deleted` as
--     eventually consistent and must NEVER treat this table as evidence a message exists or is live.
--   * messages_by_media rows are never deleted on message tombstone AT ALL — download authorization
--     is by membership, not message liveness (get_by_media_id's stated contract), so a tombstoned
--     message's reference row still authorizes recipients who legitimately received the bytes.
--
-- ACCESS PATTERNS THE KEYS SERVE (the live shape test in scylla_schema_shape_test.exs exercises
-- exactly these and fails if the deployed keys drift from this file):
--   messages_by_media:     WHERE media_id = ?                      -> all references, earliest first
--                          WHERE media_id = ? LIMIT 1              -> the EARLIEST reference
--                          (get_by_media_id's "first message carrying it" semantics)
--   media_by_conversation: WHERE conversation_id = ?
--                            [AND created_at < ?] LIMIT ?          -> gallery page, newest first
--
-- metadata VALUES follow the 001 convention: every value is JSON-encoded text. See 001's header.

USE chat_messages;

-- One row per (media, message) reference. A media_id broadcast into N conversations has N+ rows in
-- ONE partition (bounded by fan-out, small rows). sender_user_id is carried so the download oracle
-- can filter sender=owner without a second read.
CREATE TABLE IF NOT EXISTS messages_by_media (
  media_id uuid,
  created_at timestamp,
  message_id timeuuid,
  conversation_id uuid,
  sender_user_id uuid,
  PRIMARY KEY (media_id, created_at, message_id)
) WITH CLUSTERING ORDER BY (created_at ASC, message_id ASC);

-- The shared-media gallery view, newest first. `deleted` is the denormalised tombstone copy governed
-- by the invariant above.
CREATE TABLE IF NOT EXISTS media_by_conversation (
  conversation_id uuid,
  created_at timestamp,
  message_id timeuuid,
  media_id uuid,
  sender_user_id uuid,
  deleted boolean,
  metadata map<text, text>,
  PRIMARY KEY (conversation_id, created_at, message_id)
) WITH CLUSTERING ORDER BY (created_at DESC, message_id DESC);
