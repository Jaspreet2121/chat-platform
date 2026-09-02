-- 114: Nearby "stay visible" — background publishing, 8-hour retention, coarse staleness.
--
-- WHAT CHANGES, AND WHAT IT COSTS. Until now a nearby_presence row lived FIVE MINUTES and was
-- written only while the user had Nearby open: coordinates barely rested, and the product was
-- "who is here right now". The product decision is to let phones keep publishing so people stay
-- discoverable for up to EIGHT HOURS. That is a 96x increase in how long a precise coordinate sits
-- at rest, and the 101 header's promise that "coordinates expire after five minutes" is now false —
-- it is rewritten below rather than left to mislead the next reader.
--
-- The privacy posture that survives: coordinates remain server-only (never in any response), the
-- public shape is still a coarse 100/200 m bucket, expired rows are still PHYSICALLY DELETED rather
-- than filtered, and turning the master switch off still deletes the live row immediately.
--
-- The privacy posture that is NEW:
--   * auto_publish is the opt-in, DEFAULT FALSE. Publishing outside the open Nearby screen happens
--     only for users who asked for it. An absent settings row therefore means "discoverable while I
--     have Nearby open" — exactly today's behaviour — not "track me for eight hours".
--   * fix_seq lets a viewer's pinned distance bucket refresh when the TARGET actually moves, without
--     ever refreshing because the VIEWER moved. See the comment on the column.
--
-- Idempotent + transactional (fresh initdb volume AND already-running database):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../114_nearby_stay_visible.sql
BEGIN;

-- THE OPT-IN. Default false, so this migration alone changes nobody's exposure: every existing user
-- keeps publishing only while Nearby is open until they turn this on themselves.
ALTER TABLE nearby_settings
  ADD COLUMN IF NOT EXISTS auto_publish boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN nearby_settings.auto_publish IS
  'Opt-in (default false): may this account''s phones publish location while Nearby is not open? '
  'enabled=false still wins and deletes the live row; this only governs BACKGROUND publishing.';

-- THE FIX SEQUENCE. Bumped by the application only when an accepted publish MOVES the stored fix
-- materially (~>25 m); a stationary phone republishing its own coordinate every few minutes does not
-- advance it. Per-viewer bucket pins are keyed on this value, so:
--   * a viewer who moves and re-queries sees the SAME pinned bucket (anti-trilateration holds — a
--     moving attacker still cannot walk the 100/200 m boundary against a stationary target);
--   * a target who genuinely moves advances fix_seq, which retires the old pins so the bucket can
--     tell the truth again.
-- Starting at 0 for existing rows is correct: their pins were minted under the old
-- frozen-for-row-lifetime rule and stay valid until the target next moves.
ALTER TABLE nearby_presence
  ADD COLUMN IF NOT EXISTS fix_seq integer NOT NULL DEFAULT 0;

COMMENT ON COLUMN nearby_presence.fix_seq IS
  'Monotonic per-row fix generation. Advanced ONLY when an accepted publish moves the stored '
  'coordinate materially. Per-viewer distance-bucket pins are scoped to it: a moving VIEWER never '
  'resets a pin, a moving TARGET does.';

COMMENT ON COLUMN nearby_presence.updated_at IS
  'Last accepted publish. THE staleness source: discover derives a coarse last_seen_bucket from it '
  '(now / 1h / 2h / 4h / 8h) and never returns the timestamp itself.';

COMMENT ON COLUMN nearby_presence.expires_at IS
  'Hard retention edge, now up to EIGHT HOURS after the last publish (was five minutes). Rows past '
  'it are physically deleted by the next discover/publish, never merely filtered out.';

COMMENT ON TABLE nearby_presence IS
  'Live nearby coordinates. Server-only: latitude/longitude/accuracy never appear in any response — '
  'callers see a coarse 100/200 m bucket and a coarse staleness bucket. Retained up to 8h after the '
  'last publish (114); deleted immediately when the master switch goes off.';

-- THE BBOX PREFILTER INDEX. discover scans this app's live rows and computes a haversine per row;
-- an 8h TTL means the live set is now hours of publishers rather than minutes, so the scan needs a
-- prefilter. Column order is (app_id, latitude) NOT (latitude, app_id):
--   * app_id is an EQUALITY predicate and must lead for the index to be usable at all — it is also
--     the tenant boundary, so every query has it;
--   * latitude is the RANGE predicate of the bounding box and must follow the equality column;
--   * longitude is deliberately NOT a third key column. Postgres stops using a btree for further
--     range refinement after the first range key, so a third key would add write cost for no read
--     benefit. It rides as an INCLUDE payload instead, so the longitude half of the box can be
--     evaluated from the index without a heap fetch.
-- NOT a partial index: `WHERE expires_at > now()` would be rejected outright — index predicates must
-- be IMMUTABLE and now() is not. The expires_at filter stays in the query, where it belongs.
CREATE INDEX IF NOT EXISTS nearby_presence_bbox_idx
  ON nearby_presence (app_id, latitude) INCLUDE (longitude);

COMMIT;
